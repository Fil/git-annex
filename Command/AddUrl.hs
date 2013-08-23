{- git-annex command
 -
 - Copyright 2011-2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.AddUrl where

import Network.URI

import Common.Annex
import Command
import Backend
import qualified Command.Add
import qualified Annex
import qualified Annex.Queue
import qualified Backend.URL
import qualified Utility.Url as Url
import Annex.Content
import Logs.Web
import qualified Option
import Types.Key
import Types.KeySource
import Config
import Annex.Content.Direct
import Logs.Location
import qualified Logs.Transfer as Transfer
import Utility.Daemon (checkDaemon)
import Annex.Quvi
import qualified Utility.Quvi as Quvi

def :: [Command]
def = [notBareRepo $ withOptions [fileOption, pathdepthOption, relaxedOption] $
	command "addurl" (paramRepeating paramUrl) seek
		SectionCommon "add urls to annex"]

fileOption :: Option
fileOption = Option.field [] "file" paramFile "specify what file the url is added to"

pathdepthOption :: Option
pathdepthOption = Option.field [] "pathdepth" paramNumber "path components to use in filename"

relaxedOption :: Option
relaxedOption = Option.flag [] "relaxed" "skip size check"

seek :: [CommandSeek]
seek = [withField fileOption return $ \f ->
	withFlag relaxedOption $ \relaxed ->
	withField pathdepthOption (return . maybe Nothing readish) $ \d ->
	withStrings $ start relaxed f d]

start :: Bool -> Maybe FilePath -> Maybe Int -> String -> CommandStart
start relaxed optfile pathdepth s = go $ fromMaybe bad $ parseURI s
  where
  	(s', downloader) = getDownloader s
	bad = fromMaybe (error $ "bad url " ++ s') $
		parseURI $ escapeURIString isUnescapedInURI s'
	badquvi = error $ "quvi does not know how to download url " ++ s'
	choosefile = flip fromMaybe optfile
	go url = case downloader of
		QuviDownloader -> usequvi
		DefaultDownloader -> ifM (liftIO $ Quvi.supported s')
			( usequvi
			, do
				pathmax <- liftIO $ fileNameLengthLimit "."
				let file = choosefile $ url2file url pathdepth pathmax
				showStart "addurl" file
				next $ perform relaxed s' file
			)
	usequvi = do
		page <- fromMaybe badquvi
			<$> withQuviOptions Quvi.forceQuery [Quvi.quiet, Quvi.httponly] s'
		let link = fromMaybe badquvi $ headMaybe $ Quvi.pageLinks page
		let file = choosefile $ sanitizeFilePath $
			Quvi.pageTitle page ++ "." ++ Quvi.linkSuffix link
		showStart "addurl" file
		next $ performQuvi relaxed s' (Quvi.linkUrl link) file

performQuvi :: Bool -> URLString -> URLString -> FilePath -> CommandPerform
performQuvi relaxed pageurl videourl file = ifAnnexed file addurl geturl
  where
  	quviurl = setDownloader pageurl QuviDownloader
  	addurl (key, _backend) = next $ cleanup quviurl file key Nothing
	geturl = do
		key <- Backend.URL.fromUrl quviurl Nothing
		ifM (pure relaxed <||> Annex.getState Annex.fast)
			( next $ cleanup quviurl file key Nothing
			, do
				tmp <- fromRepo $ gitAnnexTmpLocation key
				showOutput
				ok <- Transfer.download webUUID key (Just file) Transfer.forwardRetry $ const $ do
					liftIO $ createDirectoryIfMissing True (parentDir tmp)
					downloadUrl [videourl] tmp
				if ok
					then next $ cleanup quviurl file key (Just tmp)
					else stop
			)

perform :: Bool -> URLString -> FilePath -> CommandPerform
perform relaxed url file = ifAnnexed file addurl geturl
  where
	geturl = next $ addUrlFile relaxed url file
	addurl (key, _backend)
		| relaxed = do
			setUrlPresent key url
			next $ return True
		| otherwise = do
			headers <- getHttpHeaders
			ifM (liftIO $ Url.check url headers $ keySize key)
				( do
					setUrlPresent key url
					next $ return True
				, do
					warning $ "failed to verify url exists: " ++ url
					stop
				)

addUrlFile :: Bool -> URLString -> FilePath -> Annex Bool
addUrlFile relaxed url file = do
	liftIO $ createDirectoryIfMissing True (parentDir file)
	ifM (Annex.getState Annex.fast <||> pure relaxed)
		( nodownload relaxed url file
		, do
			showAction $ "downloading " ++ url ++ " "
			download url file
		)

download :: URLString -> FilePath -> Annex Bool
download url file = do
	dummykey <- genkey
	tmp <- fromRepo $ gitAnnexTmpLocation dummykey
	showOutput
	ifM (runtransfer dummykey tmp)
		( do
			backend <- chooseBackend file
			let source = KeySource
				{ keyFilename = file
				, contentLocation = tmp
				, inodeCache = Nothing
				}
			k <- genKey source backend
			case k of
				Nothing -> return False
				Just (key, _) -> cleanup url file key (Just tmp)
		, return False
		)
  where
	{- Generate a dummy key to use for this download, before we can
	 - examine the file and find its real key. This allows resuming
	 - downloads, as the dummy key for a given url is stable.
	 -
	 - If the assistant is running, actually hits the url here,
	 - to get the size, so it can display a pretty progress bar.
	 -}
	genkey = do
		pidfile <- fromRepo gitAnnexPidFile
		size <- ifM (liftIO $ isJust <$> checkDaemon pidfile)
			( do
				headers <- getHttpHeaders
				liftIO $ snd <$> Url.exists url headers
			, return Nothing
			)
		Backend.URL.fromUrl url size
  	runtransfer dummykey tmp = 
		Transfer.download webUUID dummykey (Just file) Transfer.forwardRetry $ const $ do
			liftIO $ createDirectoryIfMissing True (parentDir tmp)
			downloadUrl [url] tmp
		

cleanup :: URLString -> FilePath -> Key -> Maybe FilePath -> Annex Bool
cleanup url file key mtmp = do
	when (isJust mtmp) $
		logStatus key InfoPresent
	setUrlPresent key url
	Command.Add.addLink file key False
	whenM isDirect $ do
		void $ addAssociatedFile key file
		{- For moveAnnex to work in direct mode, the symlink
		 - must already exist, so flush the queue. -}
		Annex.Queue.flush
	maybe noop (moveAnnex key) mtmp
	return True

nodownload :: Bool -> URLString -> FilePath -> Annex Bool
nodownload relaxed url file = do
	headers <- getHttpHeaders
	(exists, size) <- if relaxed
		then pure (True, Nothing)
		else liftIO $ Url.exists url headers
	if exists
		then do
			key <- Backend.URL.fromUrl url size
			cleanup url file key Nothing
		else do
			warning $ "unable to access url: " ++ url
			return False

url2file :: URI -> Maybe Int -> Int -> FilePath
url2file url pathdepth pathmax = case pathdepth of
	Nothing -> truncateFilePath pathmax $ escape fullurl
	Just depth
		| depth >= length urlbits -> frombits id
		| depth > 0 -> frombits $ drop depth
		| depth < 0 -> frombits $ reverse . take (negate depth) . reverse
		| otherwise -> error "bad --pathdepth"
  where
	fullurl = uriRegName auth ++ uriPath url ++ uriQuery url
	frombits a = intercalate "/" $ a urlbits
	urlbits = map (truncateFilePath pathmax . escape) $ filter (not . null) $ split "/" fullurl
	auth = fromMaybe (error $ "bad url " ++ show url) $ uriAuthority url
	escape = replace "/" "_" . replace "?" "_"
