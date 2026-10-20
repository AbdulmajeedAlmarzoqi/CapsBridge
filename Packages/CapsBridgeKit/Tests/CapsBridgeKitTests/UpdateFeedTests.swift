import Foundation
import Testing
@testable import CapsBridgeKit

@Suite struct UpdateFeedTests {
    private let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>CapsBridge</title>
        <item>
          <title>CapsBridge 1.0.0</title>
          <sparkle:version>1</sparkle:version>
          <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
          <description xml:lang="en" sparkle:format="markdown"><![CDATA[### 1.0.0]]></description>
          <enclosure url="https://example.com/1.zip" length="10" type="application/octet-stream" sparkle:edSignature="x"/>
        </item>
        <item>
          <title>CapsBridge 1.2.0</title>
          <sparkle:version>12</sparkle:version>
          <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>26.0.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/12.zip" length="10" type="application/octet-stream" sparkle:edSignature="y"/>
        </item>
        <item>
          <title>CapsBridge 1.1.0</title>
          <sparkle:version>9</sparkle:version>
          <enclosure url="https://example.com/9.zip" length="10" type="application/octet-stream" sparkle:edSignature="z"/>
        </item>
      </channel>
    </rss>
    <!-- sparkle-signatures:
    edSignature: abc
    length: 10
    -->
    """

    @Test func findsTheNewestItemByBuildNumber() throws {
        let newest = try #require(UpdateFeed.newestItem(in: Data(feed.utf8)))
        #expect(newest == UpdateFeedItem(version: "12", displayVersion: "1.2.0", minimumSystemVersion: "26.0.0"))
    }

    @Test func comparesBuildNumbersAsNumbers() {
        let item = UpdateFeedItem(version: "12")
        #expect(item.isNewer(than: "9"))
        #expect(!item.isNewer(than: "12"))
        #expect(!item.isNewer(than: "13"))
    }

    @Test func readsTheVersionFromAnOlderStyleEnclosure() throws {
        let old = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure url="https://example.com/a.zip" sparkle:version="3" sparkle:shortVersionString="1.3"/>
        </item></channel></rss>
        """
        #expect(UpdateFeed.newestItem(in: Data(old.utf8)) == UpdateFeedItem(version: "3", displayVersion: "1.3"))
    }

    @Test func checksTheMinimumSystemVersion() {
        let item = UpdateFeedItem(version: "2", minimumSystemVersion: "26.0.0")
        #expect(item.runs(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        #expect(item.runs(on: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)))
        #expect(!item.runs(on: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)))
    }

    @Test(arguments: ["", "not xml", "<rss><channel></channel></rss>"])
    func findsNothingInAFeedWithoutItems(text: String) {
        #expect(UpdateFeed.newestItem(in: Data(text.utf8)) == nil)
    }
}
