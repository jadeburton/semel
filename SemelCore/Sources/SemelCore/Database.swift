//
//  Database.swift
//  semel
//
//  Created by Jade Burton on 06.02.26.
//

import GRDB
import SemelNodeKit
@_exported import SemelDatabaseModels
// The engine's API speaks the cache's types — `CacheTrim` in a report, `CacheEntrySize`
// per entry, `ProcessCacheEntry` in a debug print — so whoever links the engine reads them
// without naming a second module, as with the database models above.
@_exported import SemelCache
