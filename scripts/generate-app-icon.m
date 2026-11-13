#import "keyboard-artwork.h"

static NSBitmapImageRep *renderIcon(NSInteger pixels) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:pixels
                      pixelsHigh:pixels
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    if (!bitmap)
        return nil;
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    if (!graphics)
        return nil;

    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];
    CGContextRef context = graphics.CGContext;
    CGContextClearRect(context, CGRectMake(0, 0, pixels, pixels));
    CGContextScaleCTM(context, pixels / 1024.0, pixels / 1024.0);
    CGContextSetShouldAntialias(context, true);

    // Leave breathing room around the tile, including its rounded corners.
    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(48, 48, 928, 928)
                                                      xRadius:208
                                                      yRadius:208];
    [tile addClip];
    NSGradient *background = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithCalibratedRed:0.32 green:0.12 blue:0.76 alpha:1]
                   endingColor:[NSColor colorWithCalibratedRed:0.075 green:0.035 blue:0.28 alpha:1]];
    [background drawInBezierPath:tile angle:45];

    // A separate layer lets the keys and badge gap reveal the gradient without
    // clearing the tile itself. The mark is inset so the dot fits inside it.
    CGContextBeginTransparencyLayer(context, NULL);
    CGContextTranslateCTM(context, 144, 144);
    CGContextScaleCTM(context, 736 / keyboardCanvas, 736 / keyboardCanvas);
    drawKeyboard(context);

    // Match native/macos.m's default top-right badge proportions.
    CGFloat diameter = 0.36 * keyboardCanvas, gap = 0.08 * keyboardCanvas;
    CGRect dot = CGRectMake(keyboardCanvas - diameter, keyboardCanvas - diameter,
                            diameter, diameter);
    CGContextSetBlendMode(context, kCGBlendModeClear);
    CGContextFillEllipseInRect(context, CGRectInset(dot, -gap, -gap));
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    CGContextSetRGBFillColor(context, 1, 0.25, 0.72, 1);
    CGContextFillEllipseInRect(context, dot);
    CGContextEndTransparencyLayer(context);

    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

static BOOL writeIcon(NSString *path, NSInteger pixels) {
    NSBitmapImageRep *bitmap = renderIcon(pixels);
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError *error = nil;
    if (!png || ![png writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "cannot write %s: %s\n", path.fileSystemRepresentation,
                error ? error.localizedDescription.UTF8String : "PNG rendering failed");
        return NO;
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    if (argc != 2 && argc != 3) {
        fprintf(stderr, "usage: generate-app-icon OUTPUT.png [APPICONSET]\n");
        return 2;
    }
    @autoreleasepool {
        // Read and validate the complete catalog before replacing any artwork.
        NSMutableDictionary<NSString *, NSNumber *> *outputs = [NSMutableDictionary dictionary];
        if (argc == 3) {
            NSString *directory = @(argv[2]);
            NSString *manifest = [directory stringByAppendingPathComponent:@"Contents.json"];
            NSError *error = nil;
            NSData *data = [NSData dataWithContentsOfFile:manifest options:0 error:&error];
            id catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            if (![catalog isKindOfClass:NSDictionary.class] ||
                ![catalog[@"images"] isKindOfClass:NSArray.class] || ![catalog[@"images"] count]) {
                fprintf(stderr, "cannot read icon catalog %s: %s\n", manifest.fileSystemRepresentation,
                        error ? error.localizedDescription.UTF8String : "missing images array");
                return 1;
            }
            NSSet *sizes = [NSSet setWithArray:@[@"16x16", @"32x32", @"128x128", @"256x256", @"512x512"]];
            for (id entry in catalog[@"images"]) {
                if (![entry isKindOfClass:NSDictionary.class]) {
                    fprintf(stderr, "invalid icon catalog entry\n");
                    return 1;
                }
                NSString *name = entry[@"filename"], *size = entry[@"size"], *scale = entry[@"scale"];
                if (![name isKindOfClass:NSString.class] ||
                    ![name isEqualToString:name.lastPathComponent] ||
                    ![name.pathExtension isEqualToString:@"png"] ||
                    ![size isKindOfClass:NSString.class] ||
                    ![scale isKindOfClass:NSString.class] ||
                    ![sizes containsObject:size] ||
                    ![@[@"1x", @"2x"] containsObject:scale] ||
                    ![entry[@"idiom"] isEqual:@"mac"]) {
                    fprintf(stderr, "invalid macOS icon catalog entry\n");
                    return 1;
                }
                NSString *path = [directory stringByAppendingPathComponent:name];
                if (outputs[path]) {
                    fprintf(stderr, "duplicate icon filename: %s\n", name.UTF8String);
                    return 1;
                }
                outputs[path] = @([size integerValue] * [scale integerValue]);
            }
        }
        if (!writeIcon(@(argv[1]), 1024))
            return 1;
        for (NSString *path in outputs) {
            if (!writeIcon(path, outputs[path].integerValue))
                return 1;
        }
    }
    return 0;
}
