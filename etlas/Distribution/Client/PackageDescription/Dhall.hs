{-# LANGUAGE CPP #-}
module Distribution.Client.PackageDescription.Dhall where

import qualified Data.ByteString.Char8 as BS.Char8
import Data.Function ( (&) )
import qualified Data.Text.IO as StrictText

import qualified Dhall
import DhallToCabal (dhallToCabal)

import Distribution.Verbosity
import Distribution.PackageDescription
import Distribution.PackageDescription.PrettyPrint
         (showGenericPackageDescription, writeGenericPackageDescription)
#ifdef CABAL_PARSEC
import qualified Distribution.PackageDescription.Parsec as Cabal.Parse
         (readGenericPackageDescription, parseGenericPackageDescriptionMaybe) 
#else
import Distribution.PackageDescription.Parse as Cabal.Parse
         (readGenericPackageDescription , parseGenericPackageDescription, ParseResult(..))
#endif
import Distribution.Simple.Utils (die', info)

import Lens.Micro (set)

import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, takeExtension, (</>))

import Control.Monad    (unless)

readGenericPackageDescription :: Verbosity -> FilePath -> IO GenericPackageDescription
readGenericPackageDescription verbosity path =
  if (takeExtension path) == ".dhall" then
    readDhallGenericPackageDescription verbosity path
  else
    Cabal.Parse.readGenericPackageDescription verbosity path

readDhallGenericPackageDescription :: Verbosity -> FilePath -> IO GenericPackageDescription
readDhallGenericPackageDescription verbosity dhallFilePath = do
  exists <- doesFileExist dhallFilePath
  unless exists $
    die' verbosity $
      "Error Parsing: file \"" ++ dhallFilePath ++ "\" doesn't exist. Cannot continue."
  
  let settings = Dhall.defaultInputSettings
        & set Dhall.rootDirectory ( takeDirectory dhallFilePath )
        & set Dhall.sourceName dhallFilePath

  source <- StrictText.readFile dhallFilePath
  info verbosity $ "Reading package configuration from " ++ dhallFilePath
  genPkgDesc <- explaining $ dhallToCabal settings source
  -- TODO: It should use directly the `GenericPackageDescription` generated by dhall.
  --       However, it actually has not the `condTreeConstraints` field informed and
  --       this make it unusable to be consumed by etlas/cabal
  let content = showGenericPackageDescription genPkgDesc
      result = parseCabalGenericPackageDescription content

  case result of
      Nothing -> die' verbosity $ "Failing parsing \"" ++ dhallFilePath ++ "\"."
      Just x  -> return x
  
  where
    explaining = if verbosity >= verbose then Dhall.detailed else id
 
parseCabalGenericPackageDescription :: String -> Maybe GenericPackageDescription
#ifdef CABAL_PARSEC
parseCabalGenericPackageDescription content =
        Cabal.Parse.parseGenericPackageDescriptionMaybe $ BS.Char8.pack content
#else
parseCabalGenericPackageDescription content =
      case Cabal.Parse.parseGenericPackageDescription content of
        ParseOk _ pkg -> Just pkg
        _             -> Nothing
#endif

writeDerivedCabalFile :: Verbosity -> FilePath
                      -> GenericPackageDescription -> IO FilePath
writeDerivedCabalFile verbosity dir genPkg = do
  let path = dir </> "etlas.dhall.cabal"
  info verbosity $ "Writing derived cabal file from dhall file: " ++ path
  writeGenericPackageDescription path genPkg
  return path
  
