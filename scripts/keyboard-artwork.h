#pragma once
#import <AppKit/AppKit.h>

static const CGFloat keyboardCanvas = 72;

static CGRect rectFromTop(CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    return CGRectMake(x, keyboardCanvas - y - height, width, height);
}

static void roundedRect(CGContextRef context, CGFloat x, CGFloat y, CGFloat width,
                        CGFloat height, CGFloat radius) {
    CGPathRef path = CGPathCreateWithRoundedRect(rectFromTop(x, y, width, height), radius,
                                                radius, NULL);
    CGContextAddPath(context, path);
    CGContextFillPath(context);
    CGPathRelease(path);
}

static void roundedOutline(CGContextRef context, CGFloat x, CGFloat y, CGFloat width,
                           CGFloat height, CGFloat radius) {
    CGPathRef path = CGPathCreateWithRoundedRect(rectFromTop(x, y, width, height), radius,
                                                radius, NULL);
    CGContextSetLineWidth(context, 5);
    CGContextAddPath(context, path);
    CGContextStrokePath(context);
    CGPathRelease(path);
}

// Draw into a transparent layer: the keys punch holes through the front card.
static void drawKeyboard(CGContextRef context) {
    CGContextSaveGState(context);
    CGContextSetShouldAntialias(context, true);
    CGContextSetFillColorWithColor(context, NSColor.whiteColor.CGColor);
    CGContextSetStrokeColorWithColor(context, NSColor.whiteColor.CGColor);

    // Three staggered cards, sized to remain readable at 20 points.
    roundedOutline(context, 25, 8, 40, 42, 8);
    roundedOutline(context, 18, 16, 41, 42, 8);
    roundedRect(context, 7, 23, 50, 42, 8);

    CGContextSetBlendMode(context, kCGBlendModeClear);
    // Key holes and spacebar are transparent, as required for a template.
    for (NSInteger index = 0; index < 4; index++)
        roundedRect(context, 15.5 + index * 9, 34.5, 6, 6, 2.2);
    for (NSInteger index = 0; index < 5; index++)
        roundedRect(context, 11.5 + index * 9, 44.5, 6, 6, 2.2);
    roundedRect(context, 20, 54.5, 24, 5.5, 2.75);

    CGContextRestoreGState(context);
}
