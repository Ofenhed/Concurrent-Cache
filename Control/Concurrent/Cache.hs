module Control.Concurrent.Cache (CachedData, fetch, createCache) where

import Data.Maybe (isNothing)
import Control.Concurrent (forkIO, threadDelay, killThread, MVar, modifyMVar_, readMVar, ThreadId, newMVar)
import Control.Monad (when, liftM)

data CachedData a = TimedCachedData (Int, (MVar (Maybe ThreadId, IO a, Maybe a))) | ReadOnceCachedData (MVar (Either (IO a) a))

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
        when (not $ isNothing thread) $ let Just thread' = thread in killThread thread'
        modifyMVar_ mvar $ \(_, action', value') -> do
          newThreadId <- forkIO $ do
            threadDelay timeout
            modifyMVar_ mvar $ \(_, action'', _) -> return (Nothing, action'', Nothing)
          return (Just newThreadId, action', value')
        return value'


-- |Create a cache with a timeout from an (IO ()) function.
createCache :: Int
            -- ^ @Timeout@ in microseconds before the cache is erased, 0 to
            -- disable emptying of the cache
            -> IO (a)
            -- ^ @Fetcher@, the function that returns the data which should
            -- be cached. If @Timeout@ is not set to zero, this function
            -- must be allowed to be called more than once.
            -> IO (CachedData a)
createCache 0 action = do
  var <- newMVar $ Left action
  return $ ReadOnceCachedData var

createCache timeout action = do
  var <- newMVar (Nothing, action, Nothing)
  return $ TimedCachedData (timeout, var)
