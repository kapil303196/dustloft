// One atomic script per report.
//
// Three properties matter here and none of them survive being split into
// separate round trips: an install must be counted exactly once no matter how
// often it reports, a replayed or duplicated report must add nothing, and the
// version tally must never drift from the set of installs it describes.
export const REPORT = `
local installs   = KEYS[1]
local installN   = KEYS[2]
local bytesTotal = KEYS[3]
local newDay     = KEYS[4]
local bytesDay   = KEYS[5]
local verOf      = KEYS[6]
local verCounts  = KEYS[7]

local id      = ARGV[1]
local cleaned = tonumber(ARGV[2]) or 0
local version = ARGV[3]
local ttl     = tonumber(ARGV[4])

-- HSETNX is the whole install count: it succeeds exactly once per id, for the
-- life of the store, however many times that machine reports afterwards.
local fresh = redis.call('HSETNX', installs, id, '0')
if fresh == 1 then
  redis.call('INCR', installN)
  redis.call('INCR', newDay)
  redis.call('EXPIRE', newDay, ttl)
end

-- The app sends its lifetime total, not a delta, so the difference against the
-- last stored total is what is new. A report that arrives twice, or out of
-- order after a later one, yields nothing the second time.
local prev  = tonumber(redis.call('HGET', installs, id)) or 0
local delta = cleaned - prev
if delta > 0 then
  redis.call('HSET', installs, id, string.format('%d', cleaned))
  redis.call('INCRBY', bytesTotal, string.format('%d', delta))
  redis.call('INCRBY', bytesDay, string.format('%d', delta))
  redis.call('EXPIRE', bytesDay, ttl)
else
  delta = 0
end

-- Version counts track where installs are now, not how many reports each
-- version sent, so moving an install off a version has to decrement it.
--
-- Never skipped. Skipping when the version is missing would leave an install
-- counted against whatever it last reported, or in no row at all, and the table
-- would quietly stop summing to the install count.
if version == '' then version = 'unknown' end
local was = redis.call('HGET', verOf, id)
if was ~= version then
  if was then
    local left = redis.call('HINCRBY', verCounts, was, -1)
    if left <= 0 then redis.call('HDEL', verCounts, was) end
  end
  redis.call('HINCRBY', verCounts, version, 1)
  redis.call('HSET', verOf, id, version)
end

return { fresh, string.format('%d', delta) }
`;

/**
 * Increment-and-expire, atomically.
 *
 * Done as two calls guarded by "is this the first hit", the EXPIRE can be the
 * one that fails — and the bucket then never expires, so that hashed address is
 * refused for as long as the key lives. With a fixed DUSTLOFT_IP_SALT, that is
 * forever.
 */
export const RATE_LIMIT = `
local hits = redis.call('INCR', KEYS[1])
if hits == 1 then
  redis.call('EXPIRE', KEYS[1], ARGV[1])
end
return hits
`;

/** Daily buckets are kept for just over a year, then expire on their own. */
export const DAILY_TTL_SECONDS = 400 * 24 * 60 * 60;
