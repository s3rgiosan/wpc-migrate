import XCTest
@testable import WPCMigrateKit

final class NginxConfTests: XCTestCase {
    static let stock = """
        upstream php {
          {{#each fastcgi_servers}}
          server {{this}};
          {{/each}}
        }

        server {
        	listen 127.0.0.1:{{port}};
            root   "{{root}}";

            # A comment with a } brace
            include includes/gzip.conf;

            {{#unless site.multiSite}}
            include includes/wordpress-single.conf;
            {{else}}
            include includes/wordpress-multi.conf;
            {{/unless}}

            location ~ \\.php$ {
                try_files $uri =404;
            }
        }

        """

    func testServerStatementsSplitDirectivesBlocksAndSections() throws {
        let statements = try XCTUnwrap(NginxConf.serverStatements(in: Self.stock))

        XCTAssertEqual(statements.map(\.name), [
            "listen", "root", "include",
            "{{#unless site.multiSite}}", "include", "{{else}}", "include", "{{/unless}}",
            "location",
        ])
        XCTAssertEqual(statements[0].key, "listen 127.0.0.1:{{port}};")
        XCTAssertTrue(statements[0].isTemplated)
        XCTAssertFalse(statements[2].isTemplated)
        XCTAssertEqual(statements[8].text, "location ~ \\.php$ {\n    try_files $uri =404;\n}")
    }

    func testAdditionsListOnlyTheSiteOwnStatements() throws {
        let site = Self.stock
            .replacingOccurrences(of: "\tlisten 127.0.0.1:{{port}};", with: "\tlisten {{port}};")
            .replacingOccurrences(of: "    include includes/gzip.conf;\n", with: """
                    include includes/gzip.conf;

                    # Missing uploads come from the live site
                    location ~ ^/wp-content/uploads/(.*) {
                        if (!-e $request_filename) {
                            rewrite ^/wp-content/uploads/(.*) https://example.com/wp-content/uploads/$1 redirect;
                        }
                    }
                    include example-proxy.conf;

                """)

        let additions = try XCTUnwrap(NginxConf.additions(in: site, comparedTo: Self.stock))

        XCTAssertEqual(additions.map(\.name), ["listen", "location", "include"])
        XCTAssertEqual(additions[1].text, """
            location ~ ^/wp-content/uploads/(.*) {
                if (!-e $request_filename) {
                    rewrite ^/wp-content/uploads/(.*) https://example.com/wp-content/uploads/$1 redirect;
                }
            }
            """)
    }

    func testFileWithoutAServerBlockHasNoStatements() {
        XCTAssertNil(NginxConf.serverStatements(in: "events {}\n"))
        XCTAssertNil(NginxConf.serverStatements(in: "server {\n    listen 80;\n"))
    }
}
