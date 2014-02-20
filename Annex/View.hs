{- metadata based branch views
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Annex.View where

import Common.Annex
import Types.View
import Types.MetaData
import qualified Git
import qualified Git.DiffTree as DiffTree
import qualified Git.Branch
import qualified Git.LsFiles
import qualified Git.Ref
import Git.UpdateIndex
import Git.Sha
import Git.HashObject
import Git.Types
import Git.FilePath
import qualified Backend
import Annex.Index
import Annex.Link
import Annex.CatFile
import Logs.MetaData
import Logs.View
import Utility.FileMode
import Types.Command
import Config
import CmdLine.Action

import qualified Data.Set as S
import System.Path.WildMatch
import "mtl" Control.Monad.Writer

#ifdef WITH_TDFA
import Text.Regex.TDFA
import Text.Regex.TDFA.String
#else
import Text.Regex
#endif

{- Each visible ViewFilter in a view results in another level of
 - subdirectory nesting. When a file matches multiple ways, it will appear
 - in multiple subdirectories. This means there is a bit of an exponential
 - blowup with a single file appearing in a crazy number of places!
 -
 - Capping the view size to 5 is reasonable; why wants to dig
 - through 5+ levels of subdirectories to find anything?
 -}
viewTooLarge :: View -> Bool
viewTooLarge view = visibleViewSize view > 5

visibleViewSize :: View -> Int
visibleViewSize = length . filter viewVisible . viewComponents

data ViewChange = Unchanged | Narrowing | Widening
	deriving (Ord, Eq, Show)

{- Updates a view, adding new fields to filter on (Narrowing), 
 - or allowing new values in an existing field (Widening). -}
refineView :: View -> [(MetaField, String)] -> (View, ViewChange)
refineView = go Unchanged
  where
  	go c v [] = (v, c)
	go c v ((f, s):rest) =
		let (v', c') = refineView' v f s
		in go (max c c') v' rest

{- Adds an additional filter to a view. This can only result in narrowing
 - the view. Multivalued filters are added in non-visible form. -}
filterView :: View -> [(MetaField, String)] -> View
filterView v vs = v { viewComponents = viewComponents f' ++ viewComponents v}
  where
	f = fst $ refineView (v {viewComponents = []}) vs
	f' = f { viewComponents = map toinvisible (viewComponents f) }
	toinvisible c = c { viewVisible = False }

refineView' :: View -> MetaField -> String -> (View, ViewChange)
refineView' view field wanted
	| field `elem` (map viewField components) = 
		let (components', viewchanges) = runWriter $ mapM updatefield components
		in (view { viewComponents = components' }, maximum viewchanges)
	| otherwise = 
		let component = ViewComponent field viewfilter (multiValue viewfilter)
		    view' = view { viewComponents = component : components }
		in if viewTooLarge view'
			then error $ "View is too large (" ++ show (visibleViewSize view') ++ " levels of subdirectories)"
			else (view', Narrowing)
  where
  	components = viewComponents view
	viewfilter
		| any (`elem` wanted) "*?" = FilterGlob wanted
		| otherwise = FilterValues $ S.singleton $ toMetaValue wanted
	updatefield :: ViewComponent -> Writer [ViewChange] ViewComponent
	updatefield v
		| viewField v == field = do
			let (newvf, viewchange) = combineViewFilter (viewFilter v) viewfilter
			tell [viewchange]
			return $ v { viewFilter = newvf }
		| otherwise = return v

{- Combine old and new ViewFilters, yielding a result that matches
 - either old+new, or only new.
 -
 - If we have FilterValues and change to a FilterGlob,
 - it's always a widening change, because the glob could match other
 - values. OTOH, going the other way, it's a Narrowing change if the old
 - glob matches all the new FilterValues.
 -
 - With two globs, the old one is discarded, and the new one is used.
 - We can tell if that's a narrowing change by checking if the old
 - glob matches the new glob. For example, "*" matches "foo*",
 - so that's narrowing. While "f?o" does not match "f??", so that's
 - widening.
 -}
combineViewFilter :: ViewFilter -> ViewFilter -> (ViewFilter, ViewChange)
combineViewFilter old@(FilterValues olds) (FilterValues news)
	| combined == old = (combined, Unchanged)
	| otherwise = (combined, Widening)
  where
	combined = FilterValues (S.union olds news)
combineViewFilter (FilterValues _) newglob@(FilterGlob _) =
	(newglob, Widening)
combineViewFilter (FilterGlob oldglob) new@(FilterValues s)
	| all (matchGlob (compileGlob oldglob) . fromMetaValue) (S.toList s) = (new, Narrowing)
	| otherwise = (new, Widening)
combineViewFilter (FilterGlob old) newglob@(FilterGlob new)
	| old == new = (newglob, Unchanged)
	| matchGlob (compileGlob old) new = (newglob, Narrowing)
	| otherwise = (newglob, Widening)

{- Converts a filepath used in a reference branch to the
 - filename that will be used in the view.
 -
 - No two filepaths from the same branch should yeild the same result,
 - so all directory structure needs to be included in the output file
 - in some way. However, the branch's directory structure is not relevant
 - in the view.
 -
 - So, from dir/subdir/file.foo, generate file_{dir;subdir}.foo
 -
 - (To avoid collisions with a filename that already contains {foo},
 - that is doubled to {{foo}}.)
 -}
fileViewFromReference :: MkFileView
fileViewFromReference f = concat
	[ double base
	, if null dirs then "" else "_{" ++ double (intercalate ";" dirs) ++ "}"
	, double $ concat extensions
	]
  where
	(path, basefile) = splitFileName f
	dirs = filter (/= ".") $ map dropTrailingPathSeparator (splitPath path)
	(base, extensions) = splitShortExtensions basefile

	double = replace "{" "{{" . replace "}" "}}"

fileViewReuse :: MkFileView
fileViewReuse = takeFileName

{- Generates views for a file from a branch, based on its metadata
 - and the filename used in the branch.
 -
 - Note that a file may appear multiple times in a view, when it
 - has multiple matching values for a MetaField used in the View.
 -
 - Of course if its MetaData does not match the View, it won't appear at
 - all.
 -
 - Note that for efficiency, it's useful to partially
 - evaluate this function with the view parameter and reuse
 - the result. The globs in the view will then be compiled and memoized.
 -}
fileViews :: View -> MkFileView -> FilePath -> MetaData -> [FileView]
fileViews view = 
	let matchers = map viewComponentMatcher (viewComponents view)
	in \mkfileview file metadata ->
		let matches = map (\m -> m metadata) matchers
		in if any isNothing matches
			then []
			else 
				let paths = pathProduct $
					map (map toViewPath) (visible matches)
				in if null paths
					then [mkfileview file]
					else map (</> mkfileview file) paths
  where
	visible = map (fromJust . snd) .
		filter (viewVisible . fst) .
		zip (viewComponents view)

{- Checks if metadata matches a ViewComponent filter, and if so
 - returns the value, or values that match. Self-memoizing on ViewComponent. -}
viewComponentMatcher :: ViewComponent -> (MetaData -> Maybe [MetaValue])
viewComponentMatcher viewcomponent = \metadata -> 
	let s = matcher (currentMetaDataValues metafield metadata)
	in if S.null s then Nothing else Just (S.toList s)
  where
  	metafield = viewField viewcomponent
	matcher = case viewFilter viewcomponent of
		FilterValues s -> \values -> S.intersection s values
		FilterGlob glob ->
			let regex = compileGlob glob
			in \values -> 
				S.filter (matchGlob regex . fromMetaValue) values

compileGlob :: String -> Regex
compileGlob glob = 
#ifdef WITH_TDFA
	case compile (defaultCompOpt {caseSensitive = False}) defaultExecOpt regex of
		Right r -> r
		Left _ -> error $ "failed to compile regex: " ++ regex
#else
	mkRegexWithOpts regex False True
#endif
  where
	regex = '^':wildToRegex glob

matchGlob :: Regex -> String -> Bool
matchGlob regex val = 
#ifdef WITH_TDFA
	case execute regex val of
		Right (Just _) -> True
		_ -> False
#else
	isJust $ matchRegex regex val
#endif

toViewPath :: MetaValue -> FilePath
toViewPath = concatMap escapeslash . fromMetaValue
  where
	escapeslash c
		| c == '/' = [pseudoSlash]
		| c == '\\' = [pseudoBackslash]
		| c == pseudoSlash = [pseudoSlash, pseudoSlash]
		| c == pseudoBackslash = [pseudoBackslash, pseudoBackslash]
		| otherwise = [c]

fromViewPath :: FilePath -> MetaValue
fromViewPath = toMetaValue . deescapeslash []
  where
  	deescapeslash s [] = reverse s
  	deescapeslash s (c:cs)
		| c == pseudoSlash = case cs of
			(c':cs')
				| c' == pseudoSlash -> deescapeslash (pseudoSlash:s) cs'
			_ -> deescapeslash ('/':s) cs
		| c == pseudoBackslash = case cs of
			(c':cs')
				| c' == pseudoBackslash -> deescapeslash (pseudoBackslash:s) cs'
			_ -> deescapeslash ('/':s) cs
		| otherwise = deescapeslash (c:s) cs

pseudoSlash :: Char
pseudoSlash = '\8725' -- '∕' /= '/'

pseudoBackslash :: Char
pseudoBackslash = '\9586' -- '╲' /= '\'

pathProduct :: [[FilePath]] -> [FilePath]
pathProduct [] = []
pathProduct (l:ls) = foldl combinel l ls
  where
	combinel xs ys = [combine x y | x <- xs, y <- ys]

{- Extracts the metadata from a fileview, based on the view that was used
 - to construct it. -}
fromView :: View -> FileView -> MetaData
fromView view f = foldr (uncurry updateMetaData) newMetaData (zip fields values)
  where
	visible = filter viewVisible (viewComponents view)
	fields = map viewField visible
	paths = splitDirectories $ dropFileName f
	values = map fromViewPath paths

{- Constructing a view that will match arbitrary metadata, and applying
 - it to a file yields a set of FileViews which all contain the same
 - MetaFields that were present in the input metadata
 - (excluding fields that are not visible). -}
prop_view_roundtrips :: FilePath -> MetaData -> Bool -> Bool
prop_view_roundtrips f metadata visible = null f || viewTooLarge view ||
	all hasfields (fileViews view fileViewFromReference f metadata)
  where
	view = View (Git.Ref "master") $
		map (\(mf, mv) -> ViewComponent mf (FilterValues $ S.filter (not . null . fromMetaValue) mv) visible)
			(fromMetaData metadata)
	visiblefields = sort (map viewField $ filter viewVisible (viewComponents view))
	hasfields fv = sort (map fst (fromMetaData (fromView view fv))) == visiblefields

{- Applies a view to the currently checked out branch, generating a new
 - branch for the view.
 -}
applyView :: View -> Annex Git.Branch
applyView view = applyView' fileViewFromReference view

{- Generates a new branch for a View, which must be a more narrow
 - version of the View originally used to generate the currently
 - checked out branch. That is, it must match a subset of the files
 - in view, not any others.
 -}
narrowView :: View -> Annex Git.Branch
narrowView = applyView' fileViewReuse

{- Go through each file in the currently checked out branch.
 - If the file is not annexed, skip it, unless it's a dotfile in the top.
 - Look up the metadata of annexed files, and generate any FileViews,
 - and stage them.
 -
 - Currently only works in indirect mode. Must be run from top of
 - repository.
 -}
applyView' :: MkFileView -> View -> Annex Git.Branch
applyView' mkfileview view = do
	top <- fromRepo Git.repoPath
	(l, clean) <- inRepo $ Git.LsFiles.inRepo [top]
	liftIO . nukeFile =<< fromRepo gitAnnexViewIndex
	genViewBranch view $ do
		uh <- inRepo Git.UpdateIndex.startUpdateIndex
		hasher <- inRepo hashObjectStart
		forM_ l $ \f ->
			go uh hasher f =<< Backend.lookupFile f
		liftIO $ do
			hashObjectStop hasher
			void $ stopUpdateIndex uh
			void clean
  where
	genfileviews = fileViews view mkfileview -- enables memoization
	go uh hasher f (Just (k, _)) = do
		metadata <- getCurrentMetaData k
		forM_ (genfileviews f metadata) $ \fv -> do
			stagesymlink uh hasher fv =<< inRepo (gitAnnexLink fv k)
	go uh hasher f Nothing
		| "." `isPrefixOf` f = do
			s <- liftIO $ getSymbolicLinkStatus f
			if isSymbolicLink s
				then stagesymlink uh hasher f =<< liftIO (readSymbolicLink f)
				else do
					sha <- liftIO $ Git.HashObject.hashFile hasher f
					let blobtype = if isExecutable (fileMode s)
						then ExecutableBlob
						else FileBlob
					liftIO . Git.UpdateIndex.streamUpdateIndex' uh
						=<< inRepo (Git.UpdateIndex.stageFile sha blobtype f)
		| otherwise = noop
	stagesymlink uh hasher f linktarget = do
		sha <- hashSymlink' hasher linktarget
		liftIO . Git.UpdateIndex.streamUpdateIndex' uh
			=<< inRepo (Git.UpdateIndex.stageSymlink f sha)

{- Applies a view to the reference branch, generating a new branch
 - for the View.
 -
 - This needs to work incrementally, to quickly update the view branch
 - when the reference branch is changed. So, it works based on an
 - old version of the reference branch, uses diffTree to find the
 - changes, and applies those changes to the view branch.
 -}
updateView :: View -> Git.Ref -> Git.Ref -> Annex Git.Branch
updateView view ref oldref = genViewBranch view $ do
	(diffs, cleanup) <- inRepo $ DiffTree.diffTree oldref ref
	forM_ diffs go
	void $ liftIO cleanup
  where
	go diff
		| DiffTree.dstsha diff == nullSha = error "TODO delete file"
		| otherwise = error "TODO add file"

{- Diff between currently checked out branch and staged changes, and
 - update metadata to reflect the changes that are being committed to the
 - view.
 -
 - Adding a file to a directory adds the metadata represented by
 - that directory to the file, and removing a file from a directory
 - removes the metadata.
 -
 - Note that removes must be handled before adds. This is so
 - that moving a file from x/foo/ to x/bar/ adds back the metadata for x.
 -}
withViewChanges :: (FileView -> Key -> CommandStart) -> (FileView -> Key -> CommandStart) -> Annex ()
withViewChanges addmeta removemeta = do
	makeabs <- flip fromTopFilePath <$> gitRepo
	(diffs, cleanup) <- inRepo $ DiffTree.diffIndex Git.Ref.headRef
	forM_ diffs handleremovals
	forM_ diffs (handleadds makeabs)
	void $ liftIO cleanup
  where
	handleremovals item
		| DiffTree.srcsha item /= nullSha =
			handle item removemeta
				=<< catKey (DiffTree.srcsha item) (DiffTree.srcmode item)
		| otherwise = noop
	handleadds makeabs item
		| DiffTree.dstsha item /= nullSha = 
			handle item addmeta
				=<< ifM isDirect
					( catKey (DiffTree.dstsha item) (DiffTree.dstmode item)
					-- optimisation
					, isAnnexLink $ makeabs $ DiffTree.file item
					)
		| otherwise = noop
	handle item a = maybe noop
		(void . commandAction . a (getTopFilePath $ DiffTree.file item))

{- Generates a branch for a view. This is done using a different index
 - file. An action is run to stage the files that will be in the branch.
 - Then a commit is made, to the view branch. The view branch is not
 - checked out, but entering it will display the view. -}
genViewBranch :: View -> Annex () -> Annex Git.Branch
genViewBranch view a = withIndex $ do
	a
	let branch = branchView view
	void $ inRepo $ Git.Branch.commit True (fromRef branch) branch []
	return branch

{- Runs an action using the view index file.
 - Note that the file does not necessarily exist, or can contain
 - info staged for an old view. -}
withIndex :: Annex a -> Annex a
withIndex a = do
	f <- fromRepo gitAnnexViewIndex
	withIndexFile f a

withCurrentView :: (View -> Annex a) -> Annex a
withCurrentView a = maybe (error "Not in a view.") a =<< currentView