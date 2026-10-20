import QtQuick
import QtTest
import "../contents/ui/components"

TestCase {
    id: testCase
    name: "QuotaRings"
    when: windowShown
    visible: true
    width: 240
    height: 240

    Component {
        id: fixture
        Rectangle {
            width: 200
            height: 200
            color: "black"
            property alias meters: rings.meters
            property alias animationsEnabled: rings.animationsEnabled
            QuotaRings {
                id: rings
                anchors.fill: parent
                animationsEnabled: false
            }
        }
    }

    function sample(image, radius, degrees) {
        var angle = degrees * Math.PI / 180
        return image.pixel(Math.round(image.width / 2 + radius * Math.cos(angle)),
                           Math.round(image.height / 2 + radius * Math.sin(angle)))
    }

    function render(meters) {
        var item = createTemporaryObject(fixture, testCase, { meters: meters })
        verify(waitForRendering(item))
        return grabImage(item)
    }

    function test_segments_data() {
        return [
            { tag: "full", percent: 100, warning: false, red: 1 },
            { tag: "empty", percent: 0, warning: false, red: 0.18 },
            { tag: "empty-warning", percent: 0, warning: true, red: 0.32 }
        ]
    }

    function test_segments(data) {
        var image = render([{ percent: data.percent, color: "red", warning: data.warning }])
        for (var i = 0; i < 5; ++i) {
            // Five visible pieces, with clear gaps even when the ring is full.
            fuzzyCompare(sample(image, 88, -54 + 72 * i).r, data.red, 0.03)
            fuzzyCompare(sample(image, 88, -90 + 72 * i).r, 0, 0.03)
        }
    }

    function test_fractionalQuota_data() {
        return [
            { tag: "zero", percent: 0, expected: 0 },
            { tag: "one", percent: 1, expected: 1 },
            { tag: "nineteen", percent: 19, expected: 19 },
            { tag: "boundary", percent: 20, expected: 20 },
            { tag: "twenty-one", percent: 21, expected: 21 },
            { tag: "half", percent: 50, expected: 50 },
            { tag: "ninety-nine", percent: 99, expected: 99 },
            { tag: "full", percent: 100, expected: 100 },
            { tag: "negative", percent: -10, expected: 0 },
            { tag: "overfull", percent: 120, expected: 100 },
            { tag: "invalid", percent: "unknown", expected: 0 }
        ]
    }

    function test_fractionalQuota(data) {
        var image = render([{ percent: data.percent, color: "red" }])
        // Probe either side of a 20% boundary and inside the half-full piece.
        // A rounded segment count or a zero-quota dot fails these samples.
        var quotas = [0.5, 10, 19.5, 20.5, 49, 51, 79, 81, 99.5]
        for (var i = 0; i < quotas.length; ++i) {
            var quota = quotas[i]
            var piece = Math.floor(quota / 20)
            // 8° gaps leave 64° arcs, starting 4° past twelve o'clock.
            var angle = -86 + 72 * piece + 64 * (quota % 20) / 20
            var red = sample(image, 88, angle).r
            if (quota < data.expected)
                verify(red > 0.75, "quota " + data.percent + " should fill " + quota)
            else
                verify(red < 0.4, "quota " + data.percent + " should not fill " + quota)
        }
    }

    function test_windowRemovalAndColors() {
        var item = createTemporaryObject(fixture, testCase, { meters: [
            { percent: 100, color: "red" }, { percent: 50, color: "blue" },
            { percent: 100, color: "lime" }
        ] })
        verify(waitForRendering(item))
        var image = grabImage(item)
        compare(sample(image, 88, -54).r, 1)
        compare(sample(image, 53, -54).b, 1)
        fuzzyCompare(sample(image, 53, 162).b, 0.18, 0.03)
        compare(image.pixel(100, 100), Qt.rgba(0, 0, 0, 1))
        item.meters = [{ percent: 100, color: "red" }]
        verify(waitForRendering(item))
        image = grabImage(item)
        compare(sample(image, 53, -54).b, 0)
        item.meters = []
        verify(waitForRendering(item))
        image = grabImage(item)
        compare(sample(image, 88, -54).r, 0)
    }

    function test_resizeAndAnimation() {
        var item = createTemporaryObject(fixture, testCase, {
            animationsEnabled: true, meters: [{ percent: 0, color: "red" }]
        })
        verify(waitForRendering(item))
        item.meters = [{ percent: 100, color: "red" }]
        tryVerify(function() { return sample(grabImage(item), 88, 234).r > 0.9 })
        item.meters = [{ percent: 0, color: "red" }]
        tryVerify(function() { return sample(grabImage(item), 88, -54).r < 0.3 })
        item.animationsEnabled = false
        item.meters = [{ percent: 100, color: "red" }, { percent: 100, color: "blue" }]
        var sizes = [12, 22, 32, 48]
        for (var i = 0; i < sizes.length; ++i) {
            item.width = sizes[i]
            item.height = sizes[i]
            verify(waitForRendering(item))
            var image = grabImage(item)
            compare(image.width, sizes[i])
            var redPixels = 0, bluePixels = 0
            for (var y = 0; y < image.height; ++y) {
                for (var x = 0; x < image.width; ++x) {
                    var pixel = image.pixel(x, y)
                    if (pixel.r > 0.5) ++redPixels
                    if (pixel.b > 0.5) ++bluePixels
                }
            }
            verify(redPixels > 0 && bluePixels > 0, "both windows visible at " + sizes[i] + "px")
        }
    }
}
