-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Update
-- Copyright   :  (c) David Himmelstrup 2005
-- License     :  BSD-like
--
-- Maintainer  :  lemmih@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
--
-----------------------------------------------------------------------------
{-# LANGUAGE RecordWildCards #-}
module Distribution.Client.Update
    ( update
    ) where

import Distribution.Simple.Setup
         ( fromFlag )
import Distribution.Client.Types
         ( Repo(..), RemoteRepo(..), maybeRepoRemote )
import Distribution.Client.HttpUtils
         ( DownloadResult(..) )
import Distribution.Client.FetchUtils
         ( downloadIndex )
import Distribution.Client.IndexUtils.Timestamp
import Distribution.Client.IndexUtils
         ( updateRepoIndexCache, Index(..), writeIndexTimestamp
         , currentIndexTimestamp, sendMetrics )
import Distribution.Client.Config
         ( etaHackageUrl )
import Distribution.Simple.Program
         ( gitProgram, defaultProgramDb, getProgramInvocationOutput, programInvocation,
           requireProgramVersion )
import Distribution.Client.JobControl
         ( newParallelJobControl, spawnJob, collectJob )
import Distribution.Client.Setup
         ( RepoContext(..), UpdateFlags(..) )
import Distribution.Text
         ( display )
import Distribution.Verbosity

import Distribution.Simple.Utils
         ( writeFileAtomic, warn, notice, noticeNoWrap, info )
import Distribution.Version
         ( orLaterVersion, mkVersion )
import Distribution.Client.GZipUtils ( maybeDecompress )
import System.FilePath               ( dropExtension )
import System.Directory              ( doesDirectoryExist )

import qualified Data.ByteString.Lazy       as BS
import Data.Maybe (catMaybes)
import Data.Time (getCurrentTime)
import Control.Monad
import Network.URI (uriPath)

import qualified Hackage.Security.Client as Sec

-- | 'update' downloads the package list from all known servers
update :: Verbosity -> UpdateFlags -> RepoContext -> FilePath -> Bool -> IO ()
update verbosity _ repoCtxt _ _ | null (repoContextRepos repoCtxt) = do
  warn verbosity $ "No remote package servers have been specified. Usually "
                ++ "you would have one specified in the config file."
update verbosity updateFlags repoCtxt binariesPath firstTime = do
  let repos       = repoContextRepos repoCtxt
      remoteRepos = catMaybes (map maybeRepoRemote repos)
      remoteRepoName' repo
        | remoteRepoGitIndexed repo = "git@github.com" ++ (uriPath (remoteRepoURI repo))
        | otherwise                 = remoteRepoName repo
  case remoteRepos of
    [] -> return ()
    [remoteRepo] ->
        notice verbosity $ "Downloading the latest package list from "
                        ++ remoteRepoName' remoteRepo
    _ -> notice verbosity . unlines
            $ "Downloading the latest package lists from: "
            : map (("- " ++) . remoteRepoName') remoteRepos
  jobCtrl <- newParallelJobControl (length repos)
  mapM_ (spawnJob jobCtrl . updateRepo verbosity updateFlags repoCtxt binariesPath) repos
  mapM_ (\_ -> collectJob jobCtrl) repos

  -- Update the Eta Hackage patches repository
  updatePatchRepo verbosity (repoContextPatchesDir repoCtxt)
  -- Send metrics if enabled
  sendMetrics verbosity repoCtxt firstTime

updateRepo :: Verbosity -> UpdateFlags -> RepoContext -> FilePath -> Repo -> IO ()
updateRepo verbosity updateFlags repoCtxt binariesPath repo = do
  transport <- repoContextGetTransport repoCtxt
  case repo of
    RepoLocal{..} -> return ()
    RepoRemote{..} -> do
      downloadResult <- downloadIndex verbosity transport repoRemote repoLocalDir binariesPath
      case downloadResult of
        FileAlreadyInCache -> return ()
        FileDownloaded indexPath -> do
          writeFileAtomic (dropExtension indexPath) . maybeDecompress
                                                  =<< BS.readFile indexPath
          updateRepoIndexCache verbosity (RepoIndex repoCtxt repo)
    RepoSecure{} -> repoContextWithSecureRepo repoCtxt repo $ \repoSecure -> do
      let index = RepoIndex repoCtxt repo
      -- NB: This may be a nullTimestamp if we've never updated before
      current_ts <- currentIndexTimestamp (lessVerbose verbosity) repoCtxt repo
      -- NB: always update the timestamp, even if we didn't actually
      -- download anything
      writeIndexTimestamp index (fromFlag (updateIndexState updateFlags))
      ce <- if repoContextIgnoreExpiry repoCtxt
              then Just `fmap` getCurrentTime
              else return Nothing
      updated <- Sec.uncheckClientErrors $ Sec.checkForUpdates repoSecure ce
      -- Update cabal's internal index as well so that it's not out of sync
      -- (If all access to the cache goes through hackage-security this can go)
      case updated of
        Sec.NoUpdates  ->
          return ()
        Sec.HasUpdates ->
          updateRepoIndexCache verbosity index
      -- TODO: This will print multiple times if there are multiple
      -- repositories: main problem is we don't have a way of updating
      -- a specific repo.  Once we implement that, update this.
      when (current_ts /= nullTimestamp) $
        noticeNoWrap verbosity $
          "To revert to previous state run:\n" ++
          "    etlas update --index-state='" ++ display current_ts ++ "'\n"

-- git only supports the -C flag as of 1.8.5
-- See  http://stackoverflow.com/questions/5083224/git-pull-while-not-in-a-git-directory
updatePatchRepo :: Verbosity -> FilePath -> IO ()
updatePatchRepo verbosity patchesDir = do
  notice verbosity $ "Updating the eta-hackage patch set."
  (gitProg, _, _) <- requireProgramVersion verbosity
                      gitProgram
                      (orLaterVersion (mkVersion [1,8,5]))
                      defaultProgramDb
  let runGit args =
        getProgramInvocationOutput verbosity (programInvocation gitProg args) >>=
          info verbosity
  exists <- doesDirectoryExist patchesDir
  if exists
  then runGit ["-C", patchesDir, "pull"]
  else runGit [ "clone", "--depth=1", "--config", "core.autocrlf=false"
              , etaHackageUrl, patchesDir ]
