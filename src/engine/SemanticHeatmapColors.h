#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace SemanticHeatmap {

/* -1 stricter, 0 standard, 1 broader. Scores are not rescaled.
 *
 * The stops sit on the cosine range of Apple's contextual sentence
 * embedding (NLContextualEmbedding, mean-pooled, then L2-normalized).
 * On a mix of paraphrases, related sentences and unrelated sentences
 * that range was min 0.825, max 1.000, mean 0.911. Unrelated text sat
 * near 0.83, a paraphrase near 0.93, and only the same sentence reached
 * 1. A ramp that stayed red through 0.35 and turned green only past
 * 0.90 painted that whole spread nearly one green.
 *
 * The built-in NLEmbedding sentence model on the same text ran from
 * 0.087 to 1.000, mean 0.392. Those scores are not stretched onto this
 * ramp.
 */
inline uint32_t colorBGR(double score, int sensitivity = 0) {
    static constexpr struct { double score; int r, g, b; } stops[] = {
        {0.00, 0xD6, 0x45, 0x41},
        {0.82, 0xD6, 0x45, 0x41},
        {0.85, 0xB2, 0x69, 0x64},
        {0.88, 0x8E, 0x8E, 0x8E},
        {0.90, 0x8E, 0x8E, 0x8E},
        {0.92, 0x2E, 0xCC, 0x71},
        {0.95, 0x0B, 0x8A, 0x45},
        {1.00, 0x0B, 0x8A, 0x45},
    };
    if (!std::isfinite(score)) return 0x8E8E8E;
    double t = std::clamp(score, 0.0, 1.0);
    t = std::pow(t, sensitivity < 0 ? 1.4 : sensitivity > 0 ? 0.7 : 1.0);
    for (unsigned i = 1; i < sizeof(stops) / sizeof(stops[0]); ++i) {
        if (t > stops[i].score) continue;
        const auto &a = stops[i - 1];
        const auto &b = stops[i];
        const double f = (t - a.score) / (b.score - a.score);
        const int r = static_cast<int>(a.r + (b.r - a.r) * f);
        const int g = static_cast<int>(a.g + (b.g - a.g) * f);
        const int blue = static_cast<int>(a.b + (b.b - a.b) * f);
        return static_cast<uint32_t>((blue << 16) | (g << 8) | r);
    }
    return 0x458A0B;
}

/* Six legend samples along the measured range. Band membership is the
 * nearest sample in raw score space, so a band does not move when
 * sensitivity changes the painted colors. Swatches are colored with
 * sensitivity 0. */
inline constexpr double kLegendScores[6] = {0.83, 0.86, 0.89, 0.91, 0.93, 0.96};

inline int bandForScore(double score) {
    if (!std::isfinite(score)) return -1;
    int best = 0;
    double bestDist = 2.0;
    for (int i = 0; i < 6; ++i) {
        double d = std::abs(score - kLegendScores[i]);
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

} // namespace SemanticHeatmap
