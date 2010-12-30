{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Lock where

import Control.Monad.State (liftIO)
import System.Directory

import Command
import Messages
import qualified Annex
import qualified GitRepo as Git
	
command :: [Command]
command = [Command "lock" paramPath seek "undo unlock command"]

seek :: [CommandSeek]
seek = [withFilesUnlocked start]

{- Undo unlock -}
start :: CommandStartBackendFile
start (file, _) = do
	showStart "lock" file
	return $ Just $ perform file

perform :: FilePath -> CommandPerform
perform file = do
	liftIO $ removeFile file
	g <- Annex.gitRepo
	-- first reset the file to drop any changes checked into the index
	liftIO $ Git.run g ["reset", "-q", "--", file]
	-- checkout the symlink
	liftIO $ Git.run g ["checkout", "--", file]
	return $ Just $ return True -- no cleanup needed
