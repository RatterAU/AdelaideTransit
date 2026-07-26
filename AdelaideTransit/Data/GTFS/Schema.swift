import GRDB

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE stops(
                    id TEXT PRIMARY KEY,
                    code TEXT,
                    name TEXT NOT NULL,
                    lat REAL NOT NULL,
                    lon REAL NOT NULL
                );

                CREATE VIRTUAL TABLE stops_rtree USING rtree(
                    id, min_lat, max_lat, min_lon, max_lon
                );

                CREATE TABLE routes(
                    id TEXT PRIMARY KEY,
                    short_name TEXT,
                    long_name TEXT,
                    type INTEGER NOT NULL,
                    color TEXT
                );

                CREATE TABLE trips(
                    id TEXT PRIMARY KEY,
                    route_id TEXT NOT NULL,
                    service_id TEXT NOT NULL,
                    headsign TEXT,
                    direction INTEGER,
                    shape_id TEXT
                );
                CREATE INDEX trips_route ON trips(route_id, service_id);

                CREATE TABLE stop_times(
                    trip_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    stop_id TEXT NOT NULL,
                    arr INTEGER NOT NULL,
                    dep INTEGER NOT NULL
                );
                CREATE INDEX st_stop ON stop_times(stop_id, dep);
                CREATE INDEX st_trip ON stop_times(trip_id, seq);

                CREATE TABLE shapes(
                    shape_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    lat REAL NOT NULL,
                    lon REAL NOT NULL,
                    dist REAL
                );
                CREATE INDEX shapes_id ON shapes(shape_id, seq);

                CREATE TABLE calendar(
                    service_id TEXT PRIMARY KEY,
                    monday INTEGER NOT NULL,
                    tuesday INTEGER NOT NULL,
                    wednesday INTEGER NOT NULL,
                    thursday INTEGER NOT NULL,
                    friday INTEGER NOT NULL,
                    saturday INTEGER NOT NULL,
                    sunday INTEGER NOT NULL,
                    start_date TEXT NOT NULL,
                    end_date TEXT NOT NULL
                );

                CREATE TABLE calendar_dates(
                    service_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    exception_type INTEGER NOT NULL
                );
                CREATE INDEX cal_dates_service ON calendar_dates(service_id, date);

                CREATE TABLE favourites(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    stop_id TEXT NOT NULL,
                    route_id TEXT,
                    label TEXT,
                    sort INTEGER NOT NULL DEFAULT 0,
                    grp TEXT
                );

                CREATE TABLE meta(
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }

        // Ranks each stop by how many distinct routes serve it, so that when the map has to show fewer
        // stops than exist it can drop the quiet ones and keep the interchanges — thinning that reads as
        // deliberate rather than arbitrary.
        migrator.registerMigration("v2_stop_importance") { db in
            try db.execute(sql: """
                ALTER TABLE stops ADD COLUMN importance INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX stops_importance ON stops(importance);
                """)
        }

        // A `block_id` is one physical vehicle's work. Consecutive trips in a block are the same bus, which
        // is how a 502 becomes a 110 at Stop S1 Grenfell St without the passenger moving.
        migrator.registerMigration("v3_trip_blocks") { db in
            try db.execute(sql: """
                ALTER TABLE trips ADD COLUMN block_id TEXT;
                CREATE INDEX trips_block ON trips(block_id, service_id);
                """)
            // The column arrives empty on an existing database and only ingest can fill it. Dropping the
            // stored feed identity makes the next daily check see "changed" and re-ingest, so the feature
            // heals itself on Wi-Fi instead of staying silently inert until Adelaide Metro happens to
            // publish a new timetable.
            try db.execute(sql: "DELETE FROM meta WHERE key IN ('etag', 'last_modified')")
        }

        return migrator
    }

    /// Schema for `user.sqlite` — everything the *user* created, kept in a file the feed never touches.
    ///
    /// Favourites used to live in the timetable database. That database is disposable by design: an ingest
    /// builds a replacement from the feed and swaps it in wholesale, which meant a routine timetable update
    /// could delete every starred stop. Separating the files removes the possibility rather than guarding
    /// against it — the feed cache can now be rebuilt, or deleted outright as a repair action, with nothing
    /// of the user's inside it.
    static func userMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_user") { db in
            try db.execute(sql: """
                CREATE TABLE favourites(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    stop_id TEXT NOT NULL,
                    route_id TEXT,
                    label TEXT,
                    sort INTEGER NOT NULL DEFAULT 0,
                    grp TEXT
                );
                """)
        }
        return migrator
    }

    /// Populated after stop_times and trips land, since it's derived from both.
    static func recomputeStopImportance(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TEMP TABLE stop_route_counts AS
                SELECT st.stop_id AS sid, COUNT(DISTINCT t.route_id) AS routes
                FROM stop_times st JOIN trips t ON t.id = st.trip_id
                GROUP BY st.stop_id;

            UPDATE stops SET importance =
                COALESCE((SELECT routes FROM stop_route_counts WHERE sid = stops.id), 0);

            DROP TABLE stop_route_counts;
            """)
    }
}
