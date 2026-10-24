#pragma once

#import <Foundation/Foundation.h>

/* A sentence is worth an embedding when it contains at least two words,
 * and a word is a run of letters. Digits, punctuation, bullets and list
 * markers ("1.", "- ", "***", "42)") do not count, so those segments are
 * neither embedded nor painted. */

static inline BOOL segment_has_content(NSString *text) {
    if (text.length == 0) return NO;
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSUInteger words = 0;
    BOOL inWord = NO;
    NSUInteger i = 0;
    while (i < text.length) {
        unichar cu = [text characterAtIndex:i];
        BOOL letter = NO;
        if (CFStringIsSurrogateHighCharacter(cu) && i + 1 < text.length) {
            unichar low = [text characterAtIndex:i + 1];
            if (CFStringIsSurrogateLowCharacter(low)) {
                UTF32Char u = CFStringGetLongCharacterForSurrogatePair(cu, low);
                letter = [letters longCharacterIsMember:u];
                i += 2;
            } else {
                letter = [letters characterIsMember:cu];
                i += 1;
            }
        } else {
            letter = [letters characterIsMember:cu];
            i += 1;
        }
        if (letter) {
            if (!inWord) {
                inWord = YES;
                if (++words >= 2) return YES;
            }
        } else {
            inWord = NO;
        }
    }
    return NO;
}
