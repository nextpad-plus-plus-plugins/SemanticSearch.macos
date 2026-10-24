#undef NDEBUG
#include "SemanticHeatmapColors.h"
#include <cassert>
#include <limits>

static int greenMinusRed(uint32_t bgr) {
    return static_cast<int>((bgr >> 8) & 255) - static_cast<int>(bgr & 255);
}

static void assertStopsIncrease(const SemanticHeatmap::ColorStop *stops, unsigned count) {
    assert(count >= 2);
    for (unsigned i = 1; i < count; ++i)
        assert(stops[i].score > stops[i - 1].score);
}

static void assertLegend(SemanticHeatmap::HeatmapModel model) {
    using SemanticHeatmap::bandForScore;
    using SemanticHeatmap::colorBGR;
    using SemanticHeatmap::legendScore;
    uint32_t previous = 0;
    for (int i = 0; i < 6; ++i) {
        double sample = legendScore(model, i);
        assert(bandForScore(sample, model) == i);
        uint32_t swatch = colorBGR(sample, 0, model);
        if (model == SemanticHeatmap::HeatmapModel::Contextual)
            assert(swatch == colorBGR(sample));
        if (i > 0) assert(swatch != previous);
        previous = swatch;
    }
}

int main() {
    using SemanticHeatmap::HeatmapModel;
    using SemanticHeatmap::colorBGR;
    using SemanticHeatmap::bandForScore;
    using SemanticHeatmap::kContextualStops;
    using SemanticHeatmap::kSentenceStops;
    using SemanticHeatmap::stopsFor;

    unsigned contextualCount = 0;
    unsigned sentenceCount = 0;
    const SemanticHeatmap::ColorStop *contextual = stopsFor(HeatmapModel::Contextual, contextualCount);
    const SemanticHeatmap::ColorStop *sentence = stopsFor(HeatmapModel::Sentence, sentenceCount);
    assert(contextual == kContextualStops);
    assert(sentence == kSentenceStops);
    assertStopsIncrease(contextual, contextualCount);
    assertStopsIncrease(sentence, sentenceCount);

    // Shared endpoints. The default model argument is contextual.
    assert(colorBGR(0.0) == 0x4145D6);
    assert(colorBGR(1.0) == 0x458A0B);
    assert(colorBGR(0.0, 0, HeatmapModel::Sentence) == colorBGR(0.0));
    assert(colorBGR(1.0, 0, HeatmapModel::Sentence) == colorBGR(1.0));

    // Contextual stops: red through the unrelated cluster, grey in the
    // middle, green at a paraphrase, deep green at a copy.
    assert(colorBGR(0.82) == 0x4145D6);
    assert(colorBGR(0.88) == 0x8E8E8E);
    assert(colorBGR(0.90) == 0x8E8E8E);
    assert(colorBGR(0.92) == 0x71CC2E);
    assert(colorBGR(0.95) == 0x458A0B);
    assert(bandForScore(0.83) == 0);
    assert(bandForScore(0.89) == 2);
    assert(bandForScore(0.93) == 4);
    assert(bandForScore(1.0) == 5);

    // Sentence stops, on that model's own range.
    assert(colorBGR(0.14, 0, HeatmapModel::Sentence) == 0x4145D6);
    assert(colorBGR(0.22, 0, HeatmapModel::Sentence) == 0x6469B2);
    assert(colorBGR(0.30, 0, HeatmapModel::Sentence) == 0x8E8E8E);
    assert(colorBGR(0.42, 0, HeatmapModel::Sentence) == 0x8E8E8E);
    assert(colorBGR(0.50, 0, HeatmapModel::Sentence) == 0x71CC2E);
    assert(colorBGR(0.68, 0, HeatmapModel::Sentence) == 0x458A0B);
    assert(bandForScore(0.09, HeatmapModel::Sentence) == 0);
    assert(bandForScore(0.36, HeatmapModel::Sentence) == 3);
    assert(bandForScore(0.54, HeatmapModel::Sentence) == 4);
    assert(bandForScore(1.0, HeatmapModel::Sentence) == 5);

    for (HeatmapModel model : {HeatmapModel::Contextual, HeatmapModel::Sentence}) {
        for (int sensitivity : {-1, 0, 1}) {
            assert(colorBGR(-1.0, sensitivity, model) == colorBGR(0.0, sensitivity, model));
            assert(colorBGR(2.0, sensitivity, model) == colorBGR(1.0, sensitivity, model));
            assert(colorBGR(std::numeric_limits<double>::quiet_NaN(), sensitivity, model) == 0x8E8E8E);
            assert(colorBGR(std::numeric_limits<double>::infinity(), sensitivity, model) == 0x8E8E8E);
        }
        assert(bandForScore(std::numeric_limits<double>::quiet_NaN(), model) == -1);
        assertLegend(model);
    }

    // Unrelated, mid, and paraphrase land on different colors.
    assert(greenMinusRed(colorBGR(0.83)) < greenMinusRed(colorBGR(0.89)));
    assert(greenMinusRed(colorBGR(0.89)) < greenMinusRed(colorBGR(0.93)));
    assert(greenMinusRed(colorBGR(0.09, 0, HeatmapModel::Sentence))
           < greenMinusRed(colorBGR(0.36, 0, HeatmapModel::Sentence)));
    assert(greenMinusRed(colorBGR(0.36, 0, HeatmapModel::Sentence))
           < greenMinusRed(colorBGR(0.54, 0, HeatmapModel::Sentence)));

    // The same intermediate score becomes redder in Strict and greener in Broad.
    assert(greenMinusRed(colorBGR(0.91, -1)) < greenMinusRed(colorBGR(0.91, 0)));
    assert(greenMinusRed(colorBGR(0.91, 0)) < greenMinusRed(colorBGR(0.91, 1)));
    assert(greenMinusRed(colorBGR(0.36, -1, HeatmapModel::Sentence))
           < greenMinusRed(colorBGR(0.36, 0, HeatmapModel::Sentence)));
    assert(greenMinusRed(colorBGR(0.36, 0, HeatmapModel::Sentence))
           < greenMinusRed(colorBGR(0.36, 1, HeatmapModel::Sentence)));
}
