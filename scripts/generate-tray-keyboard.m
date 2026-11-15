#import "keyboard-artwork.h"

int main(int argc, const char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: generate-tray-keyboard OUTPUT.png\n");
        return 2;
    }
    @autoreleasepool {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:(NSInteger)keyboardCanvas
                          pixelsHigh:(NSInteger)keyboardCanvas
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
        drawKeyboard(context);

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:@(argv[1]) atomically:YES]) {
            fprintf(stderr, "cannot write %s\n", argv[1]);
            return 1;
        }
    }
    return 0;
}
