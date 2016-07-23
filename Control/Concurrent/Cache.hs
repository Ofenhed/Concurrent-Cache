module Control.Concurrent.Cache (CachedData, fetch, fetchCached, createReadOnceCache, createTimedCache, createCachePassthrough) where

import Data.Maybe (isNothing)
import Control.Concurrent (forkIO, threadDelay, killThread, MVar, modifyMVar_, readMVar, ThreadId, newMVar, mkWeakMVar)
import System.Mem.Weak (deRefWeak, Weak)
import Control.Monad (when, liftM)

data Timeout = TimeSinceCreation Int | TimeSinceLastRead Int
type TimedCachedDataMVar a = MVar (Maybe ThreadId, IO a, Maybe a)

data CachedData a = TimedCachedData Timeout (TimedCachedDataMVar a) (Weak (TimedCachedDataMVar a))
                    | ReadOnceCachedData (MVar (Either (IO a) a))
                    | CachePassthrough a

-- |Only fetch data if it has been cached.
--
-- @since 0.2.1.0
fetchCached :: CachedData a
            -> IO (Maybe a)
fetchCached (ReadOnceCachedData mvar) = do
    cached <- readMVar mvar
    return $ case cached of
                  Left _ -> Nothing
                  Right value -> Just value

fetchCached (TimedCachedData timeout mvar weakMVar) = do
  (_,_,value) <- readMVar mvar
  modifyMVar_ mvar $ \mvar'@(thread', action', value') -> do
    let newThread x = do threadDelay x
                         dereffed <- deRefWeak weakMVar
                         case dereffed of
                              Just mvar'' -> modifyMVar_ mvar'' $ \(_, action'', _) -> return (Nothing, action'', Nothing)
                              Nothing -> return ()
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
  return value

fetchCached (CachePassthrough a) = return $ Just a

-- |Fetch data from a cache
--
-- @since 0.1.0.0
fetch :: CachedData a
      -> IO (a)
fetch state@(ReadOnceCachedData mvar) = go where
  go = do
    cached <- fetchCached state
    case cached of
      Nothing -> do
        modifyMVar_ mvar $ \cached' -> case cached' of
                                          Left x -> liftM Right x
                                          Right x -> return $ Right x
        go
      Just value -> return value

fetch state@(TimedCachedData timeout mvar _) = go where
  go = do
    cached <- fetchCached state
    case cached of
      Nothing -> do
        modifyMVar_ mvar $ \mvar'@(threadId, action, value) -> case value of
                                          Nothing -> do newVal <- action
                                                        return (threadId, action, Just newVal)
                                          Just x -> return $ mvar'
        go
      Just value -> return value

fetch (CachePassthrough a) = return a

-- |Create a cache which will execute an (IO ()) function on demand
-- a maximum of 1 times.
--
-- @since 0.2.0.0
createReadOnceCache  :: IO (a)
            -- ^ @Fetcher@, the function that returns the data which should
            -- be cached.
            -> IO (CachedData a)
createReadOnceCache action = do
  var <- newMVar $ Left action
  return $ ReadOnceCachedData var

-- |Create a cache with a timeout from an (IO ()) function.
--
-- @since 0.2.0.0
createTimedCache  :: Int
            -- ^ @Timeout@ in microseconds before the cache is erased
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
  weakMVar <- mkWeakMVar var $ return ()
  return $ TimedCachedData timeout' var weakMVar

-- |Create a cache variable which simply holds a value with no actual
-- caching at all.
--
-- @since 0.2.2.2
createCachePassthrough :: a
                       -- ^ @Variable@ to hold.
                       -> CachedData a
createCachePassthrough = CachePassthrough
