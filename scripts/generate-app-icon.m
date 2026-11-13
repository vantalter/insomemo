#import <AppKit/AppKit.h>

static const CGFloat canvas = 1024;
static const CGFloat templateCanvas = 72;

static CGRect rectFromTop(CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    return CGRectMake(x, templateCanvas - y - height, width, height);
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
        fprintf(stderr, "usage: generate-app-icon OUTPUT.png\n");
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
        graphics.imageInterpolation = NSImageInterpolationHigh;

        NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, canvas, canvas)
                                                             xRadius:230
                                                             yRadius:230];
        NSGradient *background = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithRed:0.32 green:0.12 blue:0.76 alpha:1]
                       endingColor:[NSColor colorWithRed:0.075 green:0.035 blue:0.28 alpha:1]];
        [background drawInBezierPath:tile angle:45];

        // Draw the same three-card keyboard and key cutouts as the tray asset,
        // at app-icon resolution so the edges stay crisp at every size.
        CGFloat scale = canvas / 72;
        CGContextRef context = graphics.CGContext;
        CGContextSaveGState(context);
        CGContextScaleCTM(context, scale, scale);
        CGContextSetShouldAntialias(context, true);
        CGContextSetFillColorWithColor(context, NSColor.whiteColor.CGColor);
        CGContextSetStrokeColorWithColor(context, NSColor.whiteColor.CGColor);
        roundedOutline(context, 25, 8, 40, 42, 8);
        roundedOutline(context, 18, 16, 41, 42, 8);
        roundedRect(context, 7, 23, 50, 42, 8);
        CGContextSetFillColorWithColor(context,
                                       [NSColor colorWithRed:0.12 green:0.045 blue:0.38 alpha:1].CGColor);
        for (NSInteger index = 0; index < 4; index++)
            roundedRect(context, 15.5 + index * 9, 34.5, 6, 6, 2.2);
        for (NSInteger index = 0; index < 5; index++)
            roundedRect(context, 11.5 + index * 9, 44.5, 6, 6, 2.2);
        roundedRect(context, 20, 54.5, 24, 5.5, 2.75);
        CGContextSetBlendMode(context, kCGBlendModeNormal);
        CGContextRestoreGState(context);

        CGFloat diameter = 0.36 * canvas, ring = 0.08 * canvas;
        NSRect badge = NSMakeRect(canvas - diameter, canvas - diameter, diameter, diameter);
        [[NSColor colorWithRed:0.075 green:0.035 blue:0.28 alpha:1]
            setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(badge, -ring, -ring)] fill];
        [[NSColor colorWithRed:1 green:0.25 blue:0.72 alpha:1] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:badge] fill];

        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [NSGraphicsContext restoreGraphicsState];
        if (![png writeToFile:@(argv[1]) atomically:YES]) {
            fprintf(stderr, "cannot write %s\n", argv[1]);
            return 1;
        }
    }
    return 0;
}
