{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module Development.NvFetcher
  ( module Development.NvFetcher.NixFetcher,
    module Development.NvFetcher.Nvchecker,
    module Development.NvFetcher.PackageSet,
    module Development.NvFetcher.Types,
    nvfetcherRules,
    Args (..),
    defaultArgs,
    defaultMain,
    generateNixSources,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Monad (unless)
import Data.Coerce (coerce)
import Data.Maybe (fromJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Development.NvFetcher.NixFetcher
import Development.NvFetcher.Nvchecker
import Development.NvFetcher.PackageSet
import Development.NvFetcher.Types
import Development.Shake
import NeatInterpolation (trimming)

data Args = Args
  { argShakeOptions :: ShakeOptions,
    argOutputFilePath :: FilePath,
    argRules :: Rules ()
  }

defaultArgs :: Args
defaultArgs = Args shakeOptions "sources.nix" $ pure ()

defaultMain :: Args -> PackageSet () -> IO ()
defaultMain Args {..} pkgSet = do
  var <- newMVar mempty
  shakeArgs
    argShakeOptions
      { shakeProgress = progressSimple,
        shakeExtra = addShakeExtra (GitCommitMessage var) mempty
      }
    $ do
      phony "clean" $ removeFilesAfter ".shake" ["//*"] >> removeFilesAfter "." [argOutputFilePath]
      argRules
      nvfetcherRules
      action $ do
        pkgs <- runPackageSet pkgSet
        generateNixSources argOutputFilePath $ Set.toList pkgs
        setCommitMessageWhenInGitHubEnv

--------------------------------------------------------------------------------
newtype GitCommitMessage = GitCommitMessage (MVar [Text])

appendGitCommitMessageLine :: Text -> Action ()
appendGitCommitMessageLine x = do
  GitCommitMessage var <- fromJust <$> getShakeExtra @GitCommitMessage
  liftIO $ modifyMVar_ var (pure . (++ [x]))

getGitCommitMessage :: Action Text
getGitCommitMessage = do
  GitCommitMessage var <- fromJust <$> getShakeExtra @GitCommitMessage
  liftIO $ T.unlines <$> readMVar var

-- | If we are in github actions, write the commit message into $COMMIT_MSG
setCommitMessageWhenInGitHubEnv :: Action ()
setCommitMessageWhenInGitHubEnv = do
  msg <- getGitCommitMessage
  getEnv "GITHUB_ENV" >>= \case
    Just env ->
      liftIO $ do
        appendFile env "COMMIT_MSG<<EOF\n"
        T.appendFile env msg
        appendFile env "\nEOF\n"
    _ -> putInfo "Not in GitHub Env"

--------------------------------------------------------------------------------

nvfetcherRules :: Rules ()
nvfetcherRules = do
  nvcheckerRule
  prefetchRule

generateNixSources :: FilePath -> [Package] -> Action ()
generateNixSources fp pkgs = do
  body <- genBody
  getGitCommitMessage >>= \msg ->
    unless (T.null msg) $
      putInfo $ T.unpack msg
  writeFileChanged fp $ T.unpack $ srouces $ T.unlines body
  produces [fp]
  where
    single Package {..} = do
      (NvcheckerResult version mOld) <- askNvchecker pversion
      prefetched <- prefetch $ pfetcher version
      appendGitCommitMessageLine
        ( pname <> ": " <> case mOld of
            Just old -> coerce old
            _ -> "∅"
            <> " → "
            <> coerce version
        )
      pure (pname, version, prefetched)
    genOne (name, coerce @Version -> ver, toNixExpr -> srcP) =
      [trimming|
        $name = {
          pname = "$name";
          version = "$ver";
          src = $srcP;
        };
      |]
    genBody = parallel $ map (fmap genOne . single) pkgs
    srouces body =
      [trimming|
        # This file was generated by nvfetcher, please do not modify it manually.
        { fetchFromGitHub, fetchurl }:
        {
          $body
        }
      |]
