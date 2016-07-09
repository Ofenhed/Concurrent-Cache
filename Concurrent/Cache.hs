module Concurrent.Cache (CachedData, fetch, createCache) where

import Data.Maybe (isNothing)
import Control.Concurrent (forkIO, threadDelay, killThread, MVar, modifyMVar_, readMVar, ThreadId, newMVar)
import Control.Monad (when)

data CachedData a = CachedData (Int, (MVar (Maybe ThreadId, IO a, Maybe a)))

-- |Fetch data from a cache
fetch :: CachedData a
      -- ^ @Cache@, the cache to fetch a value from
      -> IO (a)
fetch (CachedData (timeout, mvar)) = go where
  go = readMVar mvar >>= \(thread,_,value) -> do
    when (timeout /= 0) $ do
      when (not $ isNothing thread) $ let Just thread' = thread in killThread thread'
      modifyMVar_ mvar $ \(_, action', value') -> do
        newThreadId <- forkIO $ do
          threadDelay timeout
          modifyMVar_ mvar $ \(_, action'', _) -> return (Nothing, action'', Nothing)
        return (Just newThreadId, action', value')
    case value of
      Nothing -> do
        modifyMVar_ mvar $ \mvar'@(threadId', action', value') -> case value' of
                                          Nothing -> do newVal <- action'
                                                        return (threadId', action', Just newVal)
                                          Just x -> return $ mvar'
        go
      Just value -> return value

-- |Create a cache from an (IO ()) function.
createCache :: Int
            -- ^ @Timeout@ in microseconds before the cache is erased, 0 to
            -- disable emptying of the cache
            -> IO (a)
            -- ^ @Fetcher@, the function that returns the data which should
            -- be cached. If @Timeout@ is not set to zero, this function
            -- must be allowed to be called more than once.
            -> IO (CachedData a)
createCache timeout action = do
  var <- newMVar (Nothing, action, Nothing)
  return $ CachedData (timeout, var)
