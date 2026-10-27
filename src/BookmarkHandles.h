#pragma once
#include <set>
#include <map>

struct BookmarkHandles {
    std::set<int> handles;
    std::map<int, long> lastLines;
    std::set<long> dismissed;
};

// Handles follow edits. Deleting a line may move its marker to a neighbour.
template<class Line, class Remove, class Mask, class Add>
void syncBookmarkHandles(BookmarkHandles &state, const std::set<long> &wanted,
                         unsigned bit, Line lineOf, Remove remove, Mask mask, Add add)
{
    auto &handles = state.handles;
    if (wanted.empty()) { state.lastLines.clear(); state.dismissed.clear(); }
    std::map<int, long> nextLines;
    std::set<long> present;
    for (auto it = handles.begin(); it != handles.end();) {
        long line = lineOf(*it);
        if (line < 0 && !wanted.empty()) {
            auto old = state.lastLines.find(*it);
            if (old != state.lastLines.end()) state.dismissed.insert(old->second);
        }
        if (line >= 0 && wanted.count(line)) {
            present.insert(line); nextLines[*it] = line; ++it;
        }
        else { if (line >= 0) remove(*it); it = handles.erase(it); }
    }
    for (long line : wanted) {
        if (present.count(line) || state.dismissed.count(line) || (mask(line) & bit)) continue;
        int handle = add(line);
        if (handle >= 0) { handles.insert(handle); nextLines[handle] = line; }
    }
    state.lastLines = std::move(nextLines);
}
