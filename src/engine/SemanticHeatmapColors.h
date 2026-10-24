#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace SemanticHeatmap {

/* Which Apple NaturalLanguage model produced the score. The two models
 * live on different cosine ranges, so each has its own color stops. */
enum class HeatmapModel {
    Contextual,
    Sentence,
};

inline HeatmapModel heatmapModelFromID(const char *modelID) {
    if (modelID && std::strcmp(modelID, "sentence") == 0)
        return HeatmapModel::Sentence;
    return HeatmapModel::Contextual;
}

struct ColorStop {
    double score;
    int r, g, b;
};

/* Sensitivity is applied before the lookup: -1 uses power 1.4, 0 leaves
 * the score alone, 1 uses power 0.7. Scores are not rescaled from one
 * model onto the other. The stops were fit on one shared sample of
 * paraphrases, related sentences, and unrelated sentences.
 *
 * Contextual (NLContextualEmbedding, mean-pooled, then L2-normalized):
 * min 0.825, max 1.000, mean 0.911.
 * Percentiles p10 0.859, p25 0.893, p50 0.915, p75 0.933, p90 0.938.
 * Unrelated text sat near 0.83, a paraphrase near 0.93, and only the
 * same sentence reached 1.
 *
 * Sentence (NLEmbedding sentence embedding, L2-normalized):
 * min 0.087, max 1.000, mean 0.392.
 * Percentiles p10 0.175, p25 0.327, p50 0.393, p75 0.416, p90 0.526.
 * Unrelated text sat near 0.09 to 0.14, most other sentences clustered
 * around 0.32 to 0.43, the strongest non-copies reached about 0.54,
 * and only the same sentence reached 1.
 *
 * The tables are not a sentence-by-sentence color match. Each one
 * spreads that model's scores into a warm tail, a grey middle, a
 * green band, and deep green for a near copy. */
inline constexpr ColorStop kContextualStops[] = {
    {0.00, 0xD6, 0x45, 0x41},
    {0.82, 0xD6, 0x45, 0x41},
    {0.85, 0xB2, 0x69, 0x64},
    {0.88, 0x8E, 0x8E, 0x8E},
    {0.90, 0x8E, 0x8E, 0x8E},
    {0.92, 0x2E, 0xCC, 0x71},
    {0.95, 0x0B, 0x8A, 0x45},
    {1.00, 0x0B, 0x8A, 0x45},
};

inline constexpr ColorStop kSentenceStops[] = {
    {0.00, 0xD6, 0x45, 0x41},
    {0.14, 0xD6, 0x45, 0x41},
    {0.22, 0xB2, 0x69, 0x64},
    {0.30, 0x8E, 0x8E, 0x8E},
    {0.42, 0x8E, 0x8E, 0x8E},
    {0.50, 0x2E, 0xCC, 0x71},
    {0.68, 0x0B, 0x8A, 0x45},
    {1.00, 0x0B, 0x8A, 0x45},
};

/* Six legend samples along each measured range. Band membership is the
 * nearest sample in raw score space, so a band does not move when
 * sensitivity changes the painted colors. Swatches use sensitivity 0. */
inline constexpr double kContextualLegend[6] = {0.83, 0.86, 0.89, 0.91, 0.93, 0.96};
inline constexpr double kSentenceLegend[6] = {0.08, 0.18, 0.26, 0.36, 0.47, 0.78};

inline constexpr double kLegendScores[6] = {0.83, 0.86, 0.89, 0.91, 0.93, 0.96};

inline const ColorStop *stopsFor(HeatmapModel model, unsigned &count) {
    if (model == HeatmapModel::Sentence) {
        count = sizeof(kSentenceStops) / sizeof(kSentenceStops[0]);
        return kSentenceStops;
    }
    count = sizeof(kContextualStops) / sizeof(kContextualStops[0]);
    return kContextualStops;
}

inline double legendScore(HeatmapModel model, int index) {
    const double *table = model == HeatmapModel::Sentence ? kSentenceLegend : kContextualLegend;
    return table[index];
}

inline uint32_t colorBGR(double score, int sensitivity = 0,
                         HeatmapModel model = HeatmapModel::Contextual) {
    unsigned count = 0;
    const ColorStop *stops = stopsFor(model, count);
    if (!std::isfinite(score)) return 0x8E8E8E;
    double t = std::clamp(score, 0.0, 1.0);
    t = std::pow(t, sensitivity < 0 ? 1.4 : sensitivity > 0 ? 0.7 : 1.0);
    for (unsigned i = 1; i < count; ++i) {
        if (t > stops[i].score) continue;
        const ColorStop &a = stops[i - 1];
        const ColorStop &b = stops[i];
        const double f = (t - a.score) / (b.score - a.score);
        const int r = static_cast<int>(a.r + (b.r - a.r) * f);
        const int g = static_cast<int>(a.g + (b.g - a.g) * f);
        const int blue = static_cast<int>(a.b + (b.b - a.b) * f);
        return static_cast<uint32_t>((blue << 16) | (g << 8) | r);
    }
    return 0x458A0B;
}

inline int bandForScore(double score, HeatmapModel model = HeatmapModel::Contextual) {
    if (!std::isfinite(score)) return -1;
    int best = 0;
    double bestDist = 2.0;
    for (int i = 0; i < 6; ++i) {
        double d = std::abs(score - legendScore(model, i));
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

} // namespace SemanticHeatmap
