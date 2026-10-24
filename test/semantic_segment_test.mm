#undef NDEBUG
#import "SegmentContent.h"
#include <cassert>

int main() {
    @autoreleasepool {
        assert(!segment_has_content(@"1."));
        assert(!segment_has_content(@"- "));
        assert(!segment_has_content(@"***"));
        assert(!segment_has_content(@"42)"));
        assert(!segment_has_content(@"\u2022"));
        assert(!segment_has_content(@""));
        assert(!segment_has_content(@"   \n\t  "));
        assert(!segment_has_content(@"Hello"));
        assert(segment_has_content(@"Backup generator failed"));
        assert(segment_has_content(@"go home"));
        assert(segment_has_content(@"The museum itself was fine."));
    }
    return 0;
}
