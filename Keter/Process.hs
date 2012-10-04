{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
module Keter.Process
    ( run
    , terminate
    , Process
    ) where

import Keter.Prelude
import Keter.Logger (Logger, attach, LogPipes (..), mkLogPipe)
import Data.Time (diffUTCTime)
import Data.Conduit.Process.Unix (forkExecuteFile, waitForProcess, killProcess)
import System.Posix.Types (ProcessID)
import Prelude (error)
import Filesystem.Path.CurrentOS (encode)
import Data.Text.Encoding (encodeUtf8)
import Data.Conduit (($$))

data Status = NeedsRestart | NoRestart | Running ProcessID

-- | Run the given command, restarting if the process dies.
run :: FilePath -- ^ executable
    -> FilePath -- ^ working directory
    -> [String] -- ^ command line parameter
    -> [(String, String)] -- ^ environment
    -> Logger
    -> KIO Process
run exec dir args env logger = do
    mstatus <- newMVar NeedsRestart
    let loop mlast = do
            next <- modifyMVar mstatus $ \status ->
                case status of
                    NoRestart -> return (NoRestart, return ())
                    _ -> do
                        now <- getCurrentTime
                        case mlast of
                            Just last | diffUTCTime now last < 5 -> do
                                log $ ProcessWaiting exec
                                threadDelay $ 5 * 1000 * 1000
                            _ -> return ()
                        (pout, sout) <- mkLogPipe
                        (perr, serr) <- mkLogPipe
                        res <- liftIO $ forkExecuteFile
                            (encode exec)
                            False
                            (map encodeUtf8 args)
                            (Just $ map (encodeUtf8 *** encodeUtf8) env)
                            (Just $ encode dir)
                            (Just $ return ())
                            (Just sout)
                            (Just serr)
                        case res of
                            Left e -> do
                                void $ liftIO $ return () $$ sout
                                void $ liftIO $ return () $$ serr
                                $logEx e
                                return (NeedsRestart, return ())
                            Right pid -> do
                                attach logger $ LogPipes pout perr
                                log $ ProcessCreated exec
                                return (Running pid, liftIO (waitForProcess pid) >> loop (Just now))
            next
    forkKIO $ loop Nothing
    return $ Process mstatus

-- | Abstract type containing information on a process which will be restarted.
newtype Process = Process (MVar Status)

-- | Terminate the process and prevent it from being restarted.
terminate :: Process -> KIO ()
terminate (Process mstatus) = do
    status <- swapMVar mstatus NoRestart
    case status of
        Running pid -> void $ liftIO $ killProcess pid
        _ -> return ()
