module Control.Concurrent.Cache (CachedData, fetch, createReadOnceCache, createTimedCache) where

import Data.Maybe (isNothing)
import Control.Concurrent (forkIO, threadDelay, killThread, MVar, modifyMVar_, readMVar, ThreadId, newMVar)
import Control.Monad (when, liftM)

data Timeout = TimeSinceCreation Int | TimeSinceLastRead Int 

data CachedData a = TimedCachedData (Timeout, (MVar (Maybe ThreadId, IO a, Maybe a))) | ReadOnceCachedData (MVar (Either (IO a) a))

-- |Fetch data from a cache
fetch :: CachedData a
      -- ^ @Cache@, the cache to fetch a value from
      -> IO (a)
fetch (ReadOnceCachedData mvar) = go where
  go = do
    cached <- readMVar mvar
    case cached of
      Left _ -> do
        modifyMVar_ mvar $ \cached' -> case cached' of
                                          Left x -> do liftM Right x
                                          Right x -> return $ Right x
        go
      Right value -> return value

fetch (TimedCachedData (timeout, mvar)) = go where
  go = do
    (thread,_,value) <- readMVar mvar
    case value of
      Nothing -> do
        modifyMVar_ mvar $ \mvar'@(threadId', action', value') -> case value' of
                                          Nothing -> do newVal <- action'
                                                        return (threadId', action', Just newVal)
                                          Just x -> return $ mvar'
        go
      Just value' -> do 
        modifyMVar_ mvar $ \mvar'@(thread', action', value') -> do
          let newThread x = do threadDelay x
                               modifyMVar_ mvar $ \(_, action'', _) -> return (Nothing, action'', Nothing)
          case timeout of
               TimeSinceLastRead time -> do
                 when (not $ isNothing thread') $ let Just thread'' = thread' in killThread thread''
                 newThreadId <- forkIO $ newThread time
                 return (Just newThreadId, action', value')
               TimeSinceCreation time -> do
                 if (isNothing thread')
                    then do newThread' <- forkIO $ newThread time
                            return (Just newThread', action', value')
                    else return mvar'
        return value'


-- |Create a cache with a timeout from an (IO ()) function.
createReadOnceCache  :: IO (a)
            -- ^ @Fetcher@, the function that returns the data which should
            -- be cached. If @Timeout@ is not set to zero, this function
            -- must be allowed to be called more than once.
            -> IO (CachedData a)
createReadOnceCache action = do
  var <- newMVar $ Left action
  return $ ReadOnceCachedData var

-- |Create a cache with a timeout from an (IO ()) function.
createTimedCache  :: Int
            -- ^ @Timeout@ in microseconds before the cache is erased, 0 to
            -- disable emptying of the cache
            -> Bool
            -- ^ @resetTimerOnRead@, if true the timeout will be reset
            -- every time the cache is read, otherwise it will only be
            -- reset when the cached value is set.
            -> IO (a)
            -- ^ @Fetcher@, the function that returns the data which should
            -- be cached. If @Timeout@ is not set to zero, this function
            -- must be allowed to be called more than once.
            -> IO (CachedData a)
createTimedCache timeout resetOnRead action = do
  var <- newMVar (Nothing, action, Nothing)
  let timeout' = if resetOnRead
                   then TimeSinceLastRead timeout
                   else TimeSinceCreation timeout
  return $ TimedCachedData (timeout', var)
