{- git-annex "SHA512" backend
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Backend.SHA512 (backend) where

import Types
import Backend.SHA

backend :: Backend Annex
backend = genBackend 512
