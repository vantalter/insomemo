#import <AppKit/AppKit.h>

static const CGFloat canvas = 72;

static CGRect rectFromTop(CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    return CGRectMake(x, canvas - y - height, width, height);
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

int main(int argc, const char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: generate-tray-keyboard OUTPUT.png\n");
        return 2;
    }
    @autoreleasepool {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:(NSInteger)canvas
                          pixelsHigh:(NSInteger)canvas
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:0];
        NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:graphics];
        CGContextRef context = graphics.CGContext;
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
            roundedRect(context, 16 + index * 9, 35, 5, 5, 1.8);
        for (NSInteger index = 0; index < 5; index++)
            roundedRect(context, 12 + index * 9, 45, 5, 5, 1.8);
        roundedRect(context, 20, 55, 24, 4.5, 2.25);

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:@(argv[1]) atomically:YES]) {
            fprintf(stderr, "cannot write %s\n", argv[1]);
            return 1;
        }
    }
    return 0;
}
