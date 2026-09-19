#import "UYTDownloadsDB.h"
#import <sqlite3.h>

static NSString *UYTDownloadsDBPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docs stringByAppendingPathComponent:@"uyoudb.sqlite"];
}

BOOL UYTDownloadsDBInsertCompleted(NSString *videoID,
                                   NSString *title,
                                   NSString *channel,
                                   NSString *channelURL,
                                   NSString *qualityLabel,
                                   NSString *typeAndQuality,
                                   unsigned long long size,
                                   NSTimeInterval duration,
                                   NSString *type,
                                   NSString *path) {
    if (!videoID.length) return NO;

    NSString *dbPath = UYTDownloadsDBPath();
    sqlite3 *db = NULL;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) {
        NSLog(@"[UYTPipeline] uyoudb.sqlite open failed at %@: %s", dbPath, sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return NO;
    }

    // Same CREATE TABLE uYou itself uses (confirmed via strings on
    // uYou.dylib) - IF NOT EXISTS makes this a no-op in the normal case
    // where uYou already created the table; a safety net if we ever get
    // here first.
    const char *createSQL =
        "CREATE TABLE IF NOT EXISTS downloads ("
        "id TEXT PRIMARY KEY, videoID TEXT, title TEXT, channel TEXT, "
        "channelURL TEXT, qualityLabel TEXT, typeAndQuality TEXT, size TEXT, "
        "duration TEXT, type TEXT, path TEXT, lyrics TEXT, timestamp DATETIME)";
    char *createErr = NULL;
    if (sqlite3_exec(db, createSQL, NULL, NULL, &createErr) != SQLITE_OK) {
        NSLog(@"[UYTPipeline] uyoudb.sqlite CREATE TABLE failed: %s", createErr);
        sqlite3_free(createErr);
        sqlite3_close(db);
        return NO;
    }

    const char *insertSQL =
        "INSERT OR IGNORE INTO downloads "
        "(id, videoID, title, channel, channelURL, qualityLabel, typeAndQuality, "
        "size, duration, type, path, lyrics, timestamp) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, insertSQL, -1, &stmt, NULL) != SQLITE_OK) {
        NSLog(@"[UYTPipeline] uyoudb.sqlite prepare failed: %s", sqlite3_errmsg(db));
        sqlite3_close(db);
        return NO;
    }

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm"; // matches uYou's own format string, confirmed via strings
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];

    // id doubles as videoID: one row per video. A second SABR download of
    // the same video is silently ignored (INSERT OR IGNORE), matching
    // uYou's own de-dup behavior on this table.
    NSArray<NSString *> *values = @[
        videoID,
        videoID,
        title ?: @"",
        channel ?: @"",
        channelURL ?: @"",
        qualityLabel ?: @"",
        typeAndQuality ?: @"",
        [NSString stringWithFormat:@"%llu", size],
        [NSString stringWithFormat:@"%.0f", duration],
        type ?: @"video",
        path,
        @"", // lyrics
        timestamp,
    ];
    for (NSUInteger i = 0; i < values.count; i++) {
        sqlite3_bind_text(stmt, (int)(i + 1), [values[i] UTF8String], -1, SQLITE_TRANSIENT);
    }

    BOOL ok = (sqlite3_step(stmt) == SQLITE_DONE);
    if (!ok) NSLog(@"[UYTPipeline] uyoudb.sqlite insert failed for %@: %s", videoID, sqlite3_errmsg(db));
    else NSLog(@"[UYTPipeline] uyoudb.sqlite insert OK for %@ -> %@", videoID, path);

    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return ok;
}
