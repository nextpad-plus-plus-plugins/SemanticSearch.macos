#undef NDEBUG
#include "SemanticHeatmapColors.h"
#include <cassert>
#include <limits>

static int greenMinusRed(uint32_t bgr) {
    return static_cast<int>((bgr >> 8) & 255) - static_cast<int>(bgr & 255);
}

int main() {
    using SemanticHeatmap::colorBGR;
    using SemanticHeatmap::bandForScore;
    using SemanticHeatmap::kLegendScores;

    // Endpoints, and the red plateau through the unrelated cluster.
    assert(colorBGR(0.0) == 0x4145D6);
    assert(colorBGR(0.82) == 0x4145D6);
    assert(colorBGR(0.88) == 0x8E8E8E);
    assert(colorBGR(0.90) == 0x8E8E8E);
    assert(colorBGR(0.92) == 0x71CC2E);
    assert(colorBGR(0.95) == 0x458A0B);
    assert(colorBGR(1.0) == 0x458A0B);

    for (int sensitivity : {-1, 0, 1}) {
        assert(colorBGR(-1.0, sensitivity) == colorBGR(0.0, sensitivity));
        assert(colorBGR(2.0, sensitivity) == colorBGR(1.0, sensitivity));
        assert(colorBGR(std::numeric_limits<double>::quiet_NaN(), sensitivity) == 0x8E8E8E);
        assert(colorBGR(std::numeric_limits<double>::infinity(), sensitivity) == 0x8E8E8E);
    }

    // Unrelated, mid, and paraphrase land on different colors.
    assert(greenMinusRed(colorBGR(0.83)) < greenMinusRed(colorBGR(0.89)));
    assert(greenMinusRed(colorBGR(0.89)) < greenMinusRed(colorBGR(0.93)));
    assert(colorBGR(0.83) != colorBGR(0.89));
    assert(colorBGR(0.89) != colorBGR(0.93));

    // The same intermediate score becomes redder in Strict and greener in Broad.
    assert(greenMinusRed(colorBGR(0.91, -1)) < greenMinusRed(colorBGR(0.91, 0)));
    assert(greenMinusRed(colorBGR(0.91, 0)) < greenMinusRed(colorBGR(0.91, 1)));

    // Legend samples stay on the raw score, one band each, and differ in color.
    uint32_t previous = 0;
    for (int i = 0; i < 6; ++i) {
        assert(bandForScore(kLegendScores[i]) == i);
        uint32_t swatch = colorBGR(kLegendScores[i], 0);
        assert(swatch == colorBGR(kLegendScores[i]));
        if (i > 0) assert(swatch != previous);
        previous = swatch;
    }
    assert(bandForScore(std::numeric_limits<double>::quiet_NaN()) == -1);
}
