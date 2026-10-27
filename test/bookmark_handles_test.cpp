#include "BookmarkHandles.h"
#include <cassert>
int main() {
    BookmarkHandles owned;
    std::map<int, long> lines;
    std::set<long> user{3};
    int next = 0;
    auto sync = [&](std::set<long> want) {
        syncBookmarkHandles(owned, want, 1,
            [&](int h) { auto i=lines.find(h); return i==lines.end() ? -1L : i->second; },
            [&](int h) { lines.erase(h); },
            [&](long l) { return user.count(l) ? 1u : 0u; },
            [&](long l) { int h=next++; lines[h]=l; return h; });
    };
    sync({3,5}); assert(owned.handles.count(0) && owned.handles.size()==1);
    lines[0]=6; sync({3,6}); assert(owned.handles.count(0));
    lines[0]=4; // deleting a line moves the marker to its neighbour
    sync({3}); assert(owned.handles.empty() && lines.empty() && user.count(3));
    sync({8}); lines.clear(); // user removes bookmark
    sync({8}); assert(owned.handles.empty());
    sync({8,9}); assert(owned.handles.size()==1 && lines.begin()->second==9);
    sync({}); assert(owned.handles.empty());
    sync({8}); assert(owned.handles.size()==1);
}
