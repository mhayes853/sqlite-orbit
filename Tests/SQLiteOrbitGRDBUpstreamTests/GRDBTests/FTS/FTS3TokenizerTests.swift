// Generated from GRDB 7.11.1 Tests/GRDBTests/FTS/FTS3TokenizerTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class FTS3TokenizerTests: GRDBTestCase {
    
    private func match(_ db: Database, _ content: String, _ query: String) -> Bool {
        try! db.execute(sql: "INSERT INTO documents VALUES (?)", arguments: [content])
        defer {
            try! db.execute(sql: "DELETE FROM documents")
        }
        return try! Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: [query])! > 0
    }
    
    func testSimpleTokenizer() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .simple
            }
            
            // simple match
            XCTAssertTrue(match(db, "abcDÉF", "abcDÉF"))
            
            // English stemming
            XCTAssertFalse(match(db, "database", "databases"))
            
            // diacritics in latin characters
            XCTAssertFalse(match(db, "eéÉ", "Èèe"))
            
            // unicode case
            XCTAssertFalse(match(db, "jérôme", "JÉRÔME"))
        }
    }

    func testPorterTokenizer() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .porter
            }
            
            // simple match
            XCTAssertTrue(match(db, "abcDÉF", "abcDÉF"))
            
            // English stemming
            XCTAssertTrue(match(db, "database", "databases"))
            
            // diacritics in latin characters
            XCTAssertFalse(match(db, "eéÉ", "Èèe"))
            
            // unicode case
            XCTAssertFalse(match(db, "jérôme", "JÉRÔME"))
        }
    }

    func testUnicode61Tokenizer() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .unicode61()
            }
            
            // simple match
            XCTAssertTrue(match(db, "abcDÉF", "abcDÉF"))
            
            // English stemming
            XCTAssertFalse(match(db, "database", "databases"))
            
            // diacritics in latin characters
            XCTAssertTrue(match(db, "eéÉ", "Èèe"))
            
            // unicode case
            XCTAssertTrue(match(db, "jérôme", "JÉRÔME"))
        }
    }

    func testUnicode61TokenizerDiacriticsKeep() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .unicode61(diacritics: .keep)
            }
            
            // simple match
            XCTAssertTrue(match(db, "abcDÉF", "abcDÉF"))
            
            // English stemming
            XCTAssertFalse(match(db, "database", "databases"))
            
            // diacritics in latin characters
            XCTAssertFalse(match(db, "eéÉ", "Èèe"))
            
            // unicode case
            XCTAssertTrue(match(db, "jérôme", "JÉRÔME"))
        }
    }
    
    #if GRDBCUSTOMSQLITE || SQLITE_HAS_CODEC
    func testUnicode61TokenizerDiacriticsRemove() throws {
        guard Database.sqliteLibVersionNumber >= 3027000 else {
            throw XCTSkip("remove_diacritics=2 is not available")
        }
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
            }
            
            // simple match
            XCTAssertTrue(match(db, "abcDÉF", "abcDÉF"))
            
            // English stemming
            XCTAssertFalse(match(db, "database", "databases"))
            
            // diacritics in latin characters
            XCTAssertTrue(match(db, "eéÉ", "Èèe"))
            
            // unicode case
            XCTAssertTrue(match(db, "jérôme", "JÉRÔME"))
        }
    }
    #else
    func testUnicode61TokenizerDiacriticsRemove() throws {
        guard #available(iOS 14, macOS 10.16, tvOS 14, *) else {
            throw XCTSkip("remove_diacritics=2 is not available")
        }
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
            }
            
            // simple match
            XCTAssertTrue(match(db, "abcDÉF", "abcDÉF"))
            
            // English stemming
            XCTAssertFalse(match(db, "database", "databases"))
            
            // diacritics in latin characters
            XCTAssertTrue(match(db, "eéÉ", "Èèe"))
            
            // unicode case
            XCTAssertTrue(match(db, "jérôme", "JÉRÔME"))
        }
    }
    #endif

    func testUnicode61TokenizerSeparators() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .unicode61(separators: ["X"])
            }
            
            XCTAssertTrue(match(db, "abcXdef", "abcXdef"))
            XCTAssertTrue(match(db, "abcXdef", "defXabc"))
            XCTAssertTrue(match(db, "abcXdef", "abc"))
            XCTAssertTrue(match(db, "abcXdef", "def"))
        }
    }

    func testUnicode61TokenizerTokenCharacters() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(virtualTable: "documents", using: FTS3()) { t in
                t.tokenizer = .unicode61(tokenCharacters: Set(".-"))
            }
            
            XCTAssertTrue(match(db, "2016-10-04.txt", "2016-10-04.txt"))
            XCTAssertFalse(match(db, "2016-10-04.txt", "2016"))
            XCTAssertFalse(match(db, "2016-10-04.txt", "txt"))
        }
    }
    
    func testTokenize() throws {
        // Empty query
        try XCTAssertEqual(FTS3.tokenize(""), [])
        try XCTAssertEqual(FTS3.tokenize("", withTokenizer: .simple), [])
        try XCTAssertEqual(FTS3.tokenize("", withTokenizer: .porter), [])
        try XCTAssertEqual(FTS3.tokenize("", withTokenizer: .unicode61()), [])
        try XCTAssertEqual(FTS3.tokenize("", withTokenizer: .unicode61(diacritics: .keep)), [])
        
        try XCTAssertEqual(FTS3.tokenize("?!"), [])
        try XCTAssertEqual(FTS3.tokenize("?!", withTokenizer: .simple), [])
        try XCTAssertEqual(FTS3.tokenize("?!", withTokenizer: .porter), [])
        try XCTAssertEqual(FTS3.tokenize("?!", withTokenizer: .unicode61()), [])
        try XCTAssertEqual(FTS3.tokenize("?!", withTokenizer: .unicode61(diacritics: .keep)), [])
        
        // Token queries
        try XCTAssertEqual(FTS3.tokenize("Moby"), ["moby"])
        try XCTAssertEqual(FTS3.tokenize("Moby", withTokenizer: .simple), ["moby"])
        try XCTAssertEqual(FTS3.tokenize("Moby", withTokenizer: .porter), ["mobi"])
        try XCTAssertEqual(FTS3.tokenize("Moby", withTokenizer: .unicode61()), ["moby"])
        try XCTAssertEqual(FTS3.tokenize("Moby", withTokenizer: .unicode61(diacritics: .keep)), ["moby"])
        
        try XCTAssertEqual(FTS3.tokenize("écarlates"), ["écarlates"])
        try XCTAssertEqual(FTS3.tokenize("écarlates", withTokenizer: .simple), ["écarlates"])
        try XCTAssertEqual(FTS3.tokenize("écarlates", withTokenizer: .porter), ["écarlates"])
        try XCTAssertEqual(FTS3.tokenize("écarlates", withTokenizer: .unicode61()), ["ecarlates"])
        try XCTAssertEqual(FTS3.tokenize("écarlates", withTokenizer: .unicode61(diacritics: .keep)), ["écarlates"])
        
        try XCTAssertEqual(FTS3.tokenize("fooéı👨👨🏿🇫🇷🇨🇮"), ["fooéı👨👨🏿🇫🇷🇨🇮"])
        try XCTAssertEqual(FTS3.tokenize("fooéı👨👨🏿🇫🇷🇨🇮", withTokenizer: .simple), ["fooéı👨👨🏿🇫🇷🇨🇮"])
        try XCTAssertEqual(FTS3.tokenize("fooéı👨👨🏿🇫🇷🇨🇮", withTokenizer: .porter), ["fooéı👇�🇨🇮"]) // ¯\_(ツ)_/¯
        try XCTAssertEqual(FTS3.tokenize("fooéı👨👨🏿🇫🇷🇨🇮", withTokenizer: .unicode61()), ["fooeı", "🏿"]) // ¯\_(ツ)_/¯
        try XCTAssertEqual(FTS3.tokenize("fooéı👨👨🏿🇫🇷🇨🇮", withTokenizer: .unicode61(diacritics: .keep)), ["fooéı", "🏿"]) // ¯\_(ツ)_/¯
        
        try XCTAssertEqual(FTS3.tokenize("SQLite database"), ["sqlite", "database"])
        try XCTAssertEqual(FTS3.tokenize("SQLite database", withTokenizer: .simple), ["sqlite", "database"])
        try XCTAssertEqual(FTS3.tokenize("SQLite database", withTokenizer: .porter), ["sqlite", "databas"])
        try XCTAssertEqual(FTS3.tokenize("SQLite database", withTokenizer: .unicode61()), ["sqlite", "database"])
        try XCTAssertEqual(FTS3.tokenize("SQLite database", withTokenizer: .unicode61(diacritics: .keep)), ["sqlite", "database"])
        
        try XCTAssertEqual(FTS3.tokenize("Édouard Manet"), ["Édouard", "manet"])
        try XCTAssertEqual(FTS3.tokenize("Édouard Manet", withTokenizer: .simple), ["Édouard", "manet"])
        try XCTAssertEqual(FTS3.tokenize("Édouard Manet", withTokenizer: .porter), ["Édouard", "manet"])
        try XCTAssertEqual(FTS3.tokenize("Édouard Manet", withTokenizer: .unicode61()), ["edouard", "manet"])
        try XCTAssertEqual(FTS3.tokenize("Édouard Manet", withTokenizer: .unicode61(diacritics: .keep)), ["édouard", "manet"])
        
        // Prefix queries
        try XCTAssertEqual(FTS3.tokenize("*"), [])
        try XCTAssertEqual(FTS3.tokenize("*", withTokenizer: .simple), [])
        try XCTAssertEqual(FTS3.tokenize("*", withTokenizer: .porter), [])
        try XCTAssertEqual(FTS3.tokenize("*", withTokenizer: .unicode61()), [])
        try XCTAssertEqual(FTS3.tokenize("*", withTokenizer: .unicode61(diacritics: .keep)), [])
        
        try XCTAssertEqual(FTS3.tokenize("Robin*"), ["robin"])
        try XCTAssertEqual(FTS3.tokenize("Robin*", withTokenizer: .simple), ["robin"])
        try XCTAssertEqual(FTS3.tokenize("Robin*", withTokenizer: .porter), ["robin"])
        try XCTAssertEqual(FTS3.tokenize("Robin*", withTokenizer: .unicode61()), ["robin"])
        try XCTAssertEqual(FTS3.tokenize("Robin*", withTokenizer: .unicode61(diacritics: .keep)), ["robin"])
        
        // Phrase queries
        try XCTAssertEqual(FTS3.tokenize("\"foulent muscles\""), ["foulent", "muscles"])
        try XCTAssertEqual(FTS3.tokenize("\"foulent muscles\"", withTokenizer: .simple), ["foulent", "muscles"])
        try XCTAssertEqual(FTS3.tokenize("\"foulent muscles\"", withTokenizer: .porter), ["foulent", "muscl"])
        try XCTAssertEqual(FTS3.tokenize("\"foulent muscles\"", withTokenizer: .unicode61()), ["foulent", "muscles"])
        try XCTAssertEqual(FTS3.tokenize("\"foulent muscles\"", withTokenizer: .unicode61(diacritics: .keep)), ["foulent", "muscles"])
        
        try XCTAssertEqual(FTS3.tokenize("\"Kim Stan* Robin*\""), ["kim", "stan", "robin"])
        try XCTAssertEqual(FTS3.tokenize("\"Kim Stan* Robin*\"", withTokenizer: .simple), ["kim", "stan", "robin"])
        try XCTAssertEqual(FTS3.tokenize("\"Kim Stan* Robin*\"", withTokenizer: .porter), ["kim", "stan", "robin"])
        try XCTAssertEqual(FTS3.tokenize("\"Kim Stan* Robin*\"", withTokenizer: .unicode61()), ["kim", "stan", "robin"])
        try XCTAssertEqual(FTS3.tokenize("\"Kim Stan* Robin*\"", withTokenizer: .unicode61(diacritics: .keep)), ["kim", "stan", "robin"])
        
        // Logical queries
        try XCTAssertEqual(FTS3.tokenize("years AND months"), ["years", "and", "months"])
        try XCTAssertEqual(FTS3.tokenize("years AND months", withTokenizer: .simple), ["years", "and", "months"])
        try XCTAssertEqual(FTS3.tokenize("years AND months", withTokenizer: .porter), ["year", "and", "month"])
        try XCTAssertEqual(FTS3.tokenize("years AND months", withTokenizer: .unicode61()), ["years", "and", "months"])
        try XCTAssertEqual(FTS3.tokenize("years AND months", withTokenizer: .unicode61(diacritics: .keep)), ["years", "and", "months"])
        
        // column queries
        try XCTAssertEqual(FTS3.tokenize("title:brest"), ["title", "brest"])
        try XCTAssertEqual(FTS3.tokenize("title:brest", withTokenizer: .simple), ["title", "brest"])
        try XCTAssertEqual(FTS3.tokenize("title:brest", withTokenizer: .porter), ["titl", "brest"])
        try XCTAssertEqual(FTS3.tokenize("title:brest", withTokenizer: .unicode61()), ["title", "brest"])
        try XCTAssertEqual(FTS3.tokenize("title:brest", withTokenizer: .unicode61(diacritics: .keep)), ["title", "brest"])
    }
}
