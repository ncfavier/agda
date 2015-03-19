{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE CPP, DoAndIfThenElse #-}
-- | UHC compiler backend, main entry point.

-- In the long term, it would be nice if we could use e.g. shake to build individual Agda modules. The problem with that is that
-- some parts need to be in the TCM Monad, which doesn't easily work in shake. We would need a way to extract the information
-- out of the TCM monad, so that we can pass it to the compilation function without pulling in the TCM Monad. Another minor
-- problem might be error reporting?
module Agda.Compiler.UHC.Compiler(compilerMain) where

import Control.Applicative
import Control.Exception (try)
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid
import System.Directory ( canonicalizePath, createDirectoryIfMissing
                        , setCurrentDirectory
                        , createDirectory, doesDirectoryExist
                        , getDirectoryContents, copyFile
                        , getTemporaryDirectory, removeDirectoryRecursive
                        )
import Data.Version
import Data.List as L
import System.Exit
import System.FilePath hiding (normalise)
import System.Process hiding (env)
import System.Info (os)
import System.IO.Error (isAlreadyExistsError)
import System.IO.Temp

import Paths_Agda
import Agda.Compiler.CallCompiler
import Agda.Interaction.FindFile
import Agda.Interaction.Options
import Agda.Interaction.Imports
import qualified Agda.Syntax.Concrete.Name as CN
import Agda.Syntax.Internal hiding (Term(..))
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Serialise
import Agda.Utils.FileName
import qualified Agda.Utils.HashMap as HMap

import Agda.Compiler.UHC.Bridge as UB
import Agda.Compiler.UHC.Transform
import Agda.Compiler.UHC.ModuleInfo
import Agda.Compiler.UHC.Core
import qualified Agda.Compiler.UHC.FromAgda     as FAgda
import qualified Agda.Compiler.UHC.Smashing     as Smash
import Agda.Compiler.UHC.Naming
import Agda.Compiler.UHC.AuxAST

#include "undefined.h"
import Agda.Utils.Impossible

-- we should use a proper build system to ensure that things get only built once,
-- but better than nothing
type CompModT = StateT CompiledModules
type CompiledModules = M.Map ModuleName (AModuleInfo, AModuleInterface)

putCompModule :: Monad m => AModuleInfo -> AModuleInterface -> CompModT m ()
putCompModule amod modTrans = modify (M.insert (amiModule amod) (amod, modTrans))

installUHCAgdaBase :: TCM ()
installUHCAgdaBase = do
    srcDir <- (</> "uhc-agda-base") <$> liftIO getDataDir

    -- get user package dir
    uhcBin <- getUhcBin
    (pkgSuc, pkgDbOut, _) <- liftIO $ readProcessWithExitCode uhcBin ["--meta-pkgdir-user"] ""

    case pkgSuc of
        ExitSuccess -> do
                let pkgDbDir = head $ lines pkgDbOut

                let vers = showVersion version
                    pkgName = "uhc-agda-base-" ++ vers
                    hsFiles = ["src/UHC/Agda/Builtins.hs"]
                -- make sure pkg db dir exists
                liftIO $ createDirectoryIfMissing True pkgDbDir


                agdaBaseInstalling <- liftIO (try $ createDirectory (pkgDbDir </> "installing_" ++ pkgName))

                case agdaBaseInstalling of
                  Left e | isAlreadyExistsError e -> do
                        -- check if install finished, else abort compilation
                        agdaBaseInstalled <- liftIO (doesDirectoryExist (pkgDbDir </> "installed_" ++ pkgName))
                        case agdaBaseInstalled of
                            True  -> reportSLn "uhc" 10 $ "Agda base library " ++ pkgName ++ " is already installed."
                            False -> internalError $ unlines
                                [ "It looks like the agda base library is currently being installed by another Agda process."
                                , "Aborting this compile run, please try it again after the other Agda process finished."
                                , "You can also try deleting the directory \""
                                    ++ (pkgDbDir </> "installing_" ++ pkgName) ++ "\""
                                    ++ ", to force reinstallation of the agda base library."
                                ]
                  Left _ | otherwise -> __IMPOSSIBLE__
                  Right _ -> do
                      reportSLn "uhc" 10 $ "Agda base library " ++ pkgName ++ " missing, installing into package db at " ++ pkgDbDir ++ "."

                      -- UHC requires the source folder to be writable (see UHC bug #51)
                      -- If Agda is installed system-wide or using Nix, the cabal data files
                      -- will be readonly.
                      -- As a work around, we always copy the sources to a temporary directory for the time being.
                      -- liftIO $ setCurrentDirectory dataDir
                      -- TODO we should at least use bracket or withTempDir.. functions here, but this is tricky because
                      -- of the monad transformers.
                      dir <- liftIO $ getTemporaryDirectory >>= \t -> createTempDirectory t "uhc-agda-base-src"
                      liftIO $ copyDirContent srcDir dir
                      when (os == "linux") (liftIO $ system ("chmod -R +w \"" ++ dir ++ "\"/*") >> return ())
                      let hsFiles' = map (dir </>) hsFiles
                      callUHC1 (  ["--odir=" ++ pkgDbDir ++""
                                  , "--pkg-build=" ++ pkgName
                                  , "--pkg-build-exposed=UHC.Agda.Builtins"
                                  , "--pkg-expose=base-3.0.0.0"
                                  ] ++ hsFiles')
                      liftIO $ removeDirectoryRecursive dir
                        -- liftIO $ setCurrentDirectory pwd
                      liftIO $ createDirectory (pkgDbDir </> "installed_" ++ pkgName)
        ExitFailure _ -> internalError $ unlines
            [ "Agda couldn't find the UHC user package directory."
            ]
  where copyDirContent :: FilePath -> FilePath -> IO ()
        copyDirContent src dest = do
            createDirectoryIfMissing True dest
            chlds <- getDirectoryContents src
            mapM_ (\x -> do
                isDir <- doesDirectoryExist (src </> x)
                case isDir of
                    _ | x == "." || x == ".." -> return ()
                    True  -> copyDirContent (src </> x) (dest </> x)
                    False -> copyFile (src </> x) (dest </> x)
              ) chlds
-- | Compile an interface into an executable using UHC
compilerMain :: Interface -> TCM ()
compilerMain inter = do
    when (not uhcBackendEnabled) $ internalError "Agda has been built without UHC support."
    -- TODO do proper check for uhc existance
    let uhc_exist = ExitSuccess
    case uhc_exist of
        ExitSuccess -> do
            installUHCAgdaBase

            setUHCDir inter
            (modInfo, _) <- evalStateT (compileModule inter) M.empty
            main <- getMain inter

            -- get core name from modInfo
            let crMain = cnName $ fromJust $ qnameToCoreName (amifNameMp $ amiInterface modInfo) main

            runUhcMain modInfo crMain
            return ()

        ExitFailure _ -> internalError $ unlines
           [ "Agda cannot find the UHC compiler."
           ]

auiFile :: CN.TopLevelModuleName -> TCM FilePath
auiFile modNm = do
  let (dir, fn) = splitFileName . foldl1 (</>) $ ("Cache" : (CN.moduleNameParts modNm))
      fp  | dir == "./"  = fn
          | otherwise = dir </> fn
  liftIO $ createDirectoryIfMissing True dir
  return $ fp

outFile :: [String] -> TCM FilePath
outFile modParts = do
  let (dir, fn) = splitFileName $ foldl1 (</>) modParts
      fp  | dir == "./"  = fn
          | otherwise = dir </> fn
  liftIO $ createDirectoryIfMissing True dir
  return $ fp

-- | Compiles a module and it's imports. Returns the module info
-- of this module, and the accumulating module interface.
compileModule :: Interface -> CompModT TCM (AModuleInfo, AModuleInterface)
compileModule i = do
    -- we can't use the Core module name to get the name of the aui file,
    -- as we don't know the Core module name before we loaded/compiled the file.
    -- (well, we could just compute the module name and use that, that's
    -- probably better? )
    compMods <- get
    let modNm = iModuleName i
    let topModuleName = toTopLevelModuleName modNm
    auiFile' <- lift $ auiFile topModuleName
    -- check if this module has already been compiled
    case M.lookup modNm compMods of
        Just x -> return x
        Nothing  -> do
            imports <- map miInterface . catMaybes
                                      <$> lift (mapM (getVisitedModule . toTopLevelModuleName . fst)
                                                     (iImportedModules i))
            (curModInfos, transModInfos) <- (fmap mconcat) . unzip <$> mapM compileModule imports
            ifile <- maybe __IMPOSSIBLE__ filePath <$> lift (findInterfaceFile topModuleName)
            let uifFile = auiFile' <.> "aui"
            uptodate <- liftIO $ isNewerThan uifFile ifile
            lift $ reportSLn "UHC" 15 $ "Interface file " ++ uifFile ++ " is uptodate: " ++ show uptodate
            -- check for uhc interface file
            modInfoCached <- case uptodate of
              True  -> do
                    lift $ reportSLn "" 5 $
                        show moduleName ++ " : UHC backend interface file is up to date."
                    uif <- lift $ readModInfoFile uifFile
                    case uif of
                      Nothing -> do
                        lift $ reportSLn "" 5 $
                            show moduleName ++ " : Could not read UHC interface file, will compile this module from scratch."
                        return Nothing
                      Just uif' -> do
                        -- now check if the versions inside modInfos match with the dep info
                        let deps = amiDepsVersion uif'
                        if depsMatch deps curModInfos then do
                          lift $ reportSLn "" 1 $
                            show moduleName ++ " : module didn't change, skipping it."
                          return $ Just uif'
                        else
                          return Nothing
              False -> return Nothing

            case modInfoCached of
              Just x  -> let tmi' = transModInfos `mappend` (amiInterface x) in putCompModule x tmi' >> return (x, tmi')
              Nothing -> do
                    lift $ reportSLn "" 1 $
                        "Compiling: " ++ show (iModuleName i)
                    let defns = HMap.toList $ sigDefinitions $ iSignature i
                    opts <- lift commandLineOptions
                    (code, modInfo, _) <- lift $ compileDefns modNm curModInfos transModInfos opts defns
                    lift $ do
                        let modParts = fst $ fromMaybe __IMPOSSIBLE__ $ mnameToCoreName (amifNameMp $ amiInterface modInfo) modNm
                        crFile <- outFile modParts
                        _ <- writeCoreFile crFile code
                        writeModInfoFile uifFile modInfo

                    let tmi' = transModInfos `mappend` amiInterface modInfo
                    putCompModule modInfo tmi'
                    return (modInfo, tmi')

  where depsMatch :: [(ModuleName, ModVersion)] -> [AModuleInfo] -> Bool
        depsMatch modDeps otherMods = all (checkDep otherMods) modDeps
        checkDep :: [AModuleInfo] -> (ModuleName, ModVersion) -> Bool
        checkDep otherMods (nm, v) = case find ((nm==) . amiModule) otherMods of
                    Just v' -> (amiVersion v') == v
                    Nothing -> False

readModInfoFile :: String -> TCM (Maybe AModuleInfo)
readModInfoFile f = do
  modInfo <- liftIO (BS.readFile f) >>= decode
  return $ maybe Nothing (\mi ->
    if amiFileVersion mi == currentModInfoVersion
        && amiAgdaVersion mi == currentInterfaceVersion then
      Just mi
    else
      Nothing) modInfo

writeModInfoFile :: String -> AModuleInfo -> TCM ()
writeModInfoFile f mi = do
  mi' <- encode mi
  liftIO $ BS.writeFile f mi'

getMain :: MonadTCM m => Interface -> m QName
getMain iface = case concatMap f defs of
    [] -> typeError $ GenericError $ "Could not find main."
    [x] -> return x
    _   -> __IMPOSSIBLE__
  where defs = HMap.toList $ sigDefinitions $ iSignature iface
        f (qn, def) = case theDef def of
            (Function{}) | "main" == show (qnameName qn) -> [qn]
            _   -> []

idPrint :: String -> Transform -> Transform
idPrint s m x = do
  reportSLn "uhc.phases" 10 s
  m x

-- | Perform the chain of compilation stages, from definitions to UHC Core code
compileDefns :: ModuleName
    -> [AModuleInfo] -- ^ top level imports
    -> AModuleInterface -- ^ transitive iface
    -> CommandLineOptions
    -> [(QName, Definition)] -> TCM (UB.CModule, AModuleInfo, AMod)
compileDefns modNm curModImps transModIface opts defs = do

    (amod', modInfo) <- FAgda.fromAgdaModule modNm curModImps transModIface defs $ \amod ->
                   return amod
               >>= optim optOptimSmashing "smashing"      Smash.smash'em
               >>= idPrint "done" return
    reportSLn "uhc" 10 $ "Done generating AuxAST for \"" ++ show modNm ++ "\"."
    crMod <- toCore amod' modInfo (transModIface `mappend` (amiInterface modInfo)) curModImps

    reportSLn "uhc" 10 $ "Done generating Core for \"" ++ show modNm ++ "\"."
    return (crMod, modInfo, amod')
  where optim :: (CommandLineOptions -> Bool) -> String -> Transform -> Transform
        optim p s m x | p opts = idPrint s m x
                      | otherwise = return x

writeCoreFile :: String -> UB.CModule -> TCM FilePath
writeCoreFile f cmod = do
  useTextual <- optUHCTextualCore <$> commandLineOptions

  -- dump textual core, useful for debugging.
  when useTextual (do
    let f' = f <.> ".dbg.tcr"
    reportSLn "uhc" 10 $ "Writing textual core to \"" ++ show f' ++ "\"."
    liftIO $ putPPFile f' (UB.printModule defaultEHCOpts cmod) 200
    )

  let f' = f <.> ".bcr"
  reportSLn "uhc" 10 $ "Writing binary core to \"" ++ show f' ++ "\"."
  liftIO $ putSerializeFile f' cmod
  return f'

-- | Change the current directory to UHC folder, create it if it doesn't already
--   exist.
setUHCDir :: Interface -> TCM ()
setUHCDir mainI = do
    let tm = toTopLevelModuleName $ iModuleName mainI
    f <- findFile tm
    compileDir' <- gets (fromMaybe (filePath $ CN.projectRoot f tm) .
                                  optCompileDir . stPersistentOptions . stPersistentState)
    compileDir <- liftIO $ canonicalizePath compileDir'
    liftIO $ setCurrentDirectory compileDir
    liftIO $ createDirectoryIfMissing False "UHC"
    liftIO $ setCurrentDirectory $ compileDir </> "UHC"

-- | Create the UHC Core main file, which calls the Agda main function
runUhcMain :: AModuleInfo -> HsName -> TCM ()
runUhcMain mainMod mainName = do
    let fp = "Main"
    let mmod = createMainModule mainMod mainName
    fp' <- writeCoreFile fp mmod
    -- TODO drop the RTS args as soon as we don't need the additional memory anymore
    callUHC1 ["--output=" ++ (show $ last $ mnameToList $ amiModule mainMod), fp', "+RTS", "-K50m", "-RTS"]

callUHC1 :: [String] -> TCM ()
callUHC1 args = do
    uhcBin <- getUhcBin
    doCall <- optUHCCallUHC <$> commandLineOptions
    when doCall (callCompiler uhcBin args)

getUhcBin :: TCM FilePath
getUhcBin = fromMaybe ("uhc") . optUHCBin <$> commandLineOptions

