// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2009-2019 Camilla Löwy <elmindreda@glfw.org>
// SPDX-FileCopyrightText: 2023 The Ebitengine Authors

#include "internal_unix.h"

#include <float.h>
#include <string.h>

// HACK: This enum value is missing from framework headers on OS X 10.11 despite
//       having been (according to documentation) added in Mac OS X 10.7
#define NSWindowCollectionBehaviorFullScreenNone (1 << 9)

// Returns whether the cursor is in the content area of the specified window
//
static GLFWbool cursorInContentArea(_GLFWwindow* window)
{
    const NSPoint pos = [window->ns.object mouseLocationOutsideOfEventStream];
    return [window->ns.view mouse:pos inRect:[window->ns.view frame]];
}

// Hides the cursor if not already hidden
//
static void hideCursor(_GLFWwindow* window)
{
    if (!_glfw.ns.cursorHidden)
    {
        [NSCursor hide];
        _glfw.ns.cursorHidden = GLFW_TRUE;
    }
}

// Shows the cursor if not already shown
//
static void showCursor(_GLFWwindow* window)
{
    if (_glfw.ns.cursorHidden)
    {
        [NSCursor unhide];
        _glfw.ns.cursorHidden = GLFW_FALSE;
    }
}

// Updates the cursor image according to its cursor mode
//
static void updateCursorImage(_GLFWwindow* window)
{
    if (window->cursorMode == GLFW_CURSOR_NORMAL)
    {
        showCursor(window);

        if (window->cursor)
            [(NSCursor*) window->cursor->ns.object set];
        else
            [[NSCursor arrowCursor] set];
    }
    else
        hideCursor(window);
}

// Apply chosen cursor mode to a focused window
//
static void updateCursorMode(_GLFWwindow* window)
{
    if (window->cursorMode == GLFW_CURSOR_DISABLED)
    {
        _glfw.ns.disabledCursorWindow = window;
        _glfwPlatformGetCursorPos(window,
                                  &_glfw.ns.restoreCursorPosX,
                                  &_glfw.ns.restoreCursorPosY);
        _glfwCenterCursorInContentArea(window);
        CGAssociateMouseAndMouseCursorPosition(false);
    }
    else if (_glfw.ns.disabledCursorWindow == window)
    {
        _glfw.ns.disabledCursorWindow = NULL;
        _glfwPlatformSetCursorPos(window,
                                  _glfw.ns.restoreCursorPosX,
                                  _glfw.ns.restoreCursorPosY);
        // NOTE: The matching CGAssociateMouseAndMouseCursorPosition call is
        //       made in _glfwPlatformSetCursorPos as part of a workaround
    }

    if (cursorInContentArea(window))
        updateCursorImage(window);
}

// Make the specified window and its video mode active on its monitor
//
static void acquireMonitor(_GLFWwindow* window)
{
    _glfwSetVideoModeNS(window->monitor, &window->videoMode);
    const CGRect bounds = CGDisplayBounds(window->monitor->ns.displayID);
    const NSRect frame = NSMakeRect(bounds.origin.x,
                                    _glfwTransformYNS(bounds.origin.y + bounds.size.height - 1),
                                    bounds.size.width,
                                    bounds.size.height);

    [window->ns.object setFrame:frame display:YES];

    _glfwInputMonitorWindow(window->monitor, window);
}

// Remove the window and restore the original video mode
//
static void releaseMonitor(_GLFWwindow* window)
{
    if (window->monitor->window != window)
        return;

    _glfwInputMonitorWindow(window->monitor, NULL);
    _glfwRestoreVideoModeNS(window->monitor);
}

// Translates macOS key modifiers into GLFW ones
//
static int translateFlags(NSUInteger flags)
{
    int mods = 0;

    if (flags & NSEventModifierFlagShift)
        mods |= GLFW_MOD_SHIFT;
    if (flags & NSEventModifierFlagControl)
        mods |= GLFW_MOD_CONTROL;
    if (flags & NSEventModifierFlagOption)
        mods |= GLFW_MOD_ALT;
    if (flags & NSEventModifierFlagCommand)
        mods |= GLFW_MOD_SUPER;
    if (flags & NSEventModifierFlagCapsLock)
        mods |= GLFW_MOD_CAPS_LOCK;

    return mods;
}

// Translates a macOS keycode to a GLFW keycode
//
static int translateKey(unsigned int key)
{
    if (key >= sizeof(_glfw.ns.keycodes) / sizeof(_glfw.ns.keycodes[0]))
        return GLFW_KEY_UNKNOWN;

    return _glfw.ns.keycodes[key];
}

// Translate a GLFW keycode to a Cocoa modifier flag
//
static NSUInteger translateKeyToModifierFlag(int key)
{
    switch (key)
    {
        case GLFW_KEY_LEFT_SHIFT:
        case GLFW_KEY_RIGHT_SHIFT:
            return NSEventModifierFlagShift;
        case GLFW_KEY_LEFT_CONTROL:
        case GLFW_KEY_RIGHT_CONTROL:
            return NSEventModifierFlagControl;
        case GLFW_KEY_LEFT_ALT:
        case GLFW_KEY_RIGHT_ALT:
            return NSEventModifierFlagOption;
        case GLFW_KEY_LEFT_SUPER:
        case GLFW_KEY_RIGHT_SUPER:
            return NSEventModifierFlagCommand;
        case GLFW_KEY_CAPS_LOCK:
            return NSEventModifierFlagCapsLock;
    }

    return 0;
}

// Defines a constant for empty ranges in NSTextInputClient
//
static const NSRange kEmptyRange = { NSNotFound, 0 };


//------------------------------------------------------------------------
// Delegate for window related notifications
//------------------------------------------------------------------------

@interface GLFWWindowDelegate : NSObject
{
    _GLFWwindow* window;
}

- (instancetype)initWithGlfwWindow:(_GLFWwindow *)initWindow;

@end

@implementation GLFWWindowDelegate

- (instancetype)initWithGlfwWindow:(_GLFWwindow *)initWindow
{
    self = [super init];
    if (self != nil)
        window = initWindow;

    return self;
}

- (BOOL)windowShouldClose:(id)sender
{
    _glfwInputWindowCloseRequest(window);
    return NO;
}

- (void)windowDidResize:(NSNotification *)notification
{
    if (window->context.source == GLFW_NATIVE_CONTEXT_API)
        [window->context.nsgl.object update];

    if (_glfw.ns.disabledCursorWindow == window)
        _glfwCenterCursorInContentArea(window);

    const int maximized = [window->ns.object isZoomed];
    if (window->ns.maximized != maximized)
    {
        window->ns.maximized = maximized;
        _glfwInputWindowMaximize(window, maximized);
    }

    const NSRect contentRect = [window->ns.view frame];
    const NSRect fbRect = [window->ns.view convertRectToBacking:contentRect];

    if (fbRect.size.width != window->ns.fbWidth ||
        fbRect.size.height != window->ns.fbHeight)
    {
        window->ns.fbWidth  = fbRect.size.width;
        window->ns.fbHeight = fbRect.size.height;
        _glfwInputFramebufferSize(window, fbRect.size.width, fbRect.size.height);
    }

    if (contentRect.size.width != window->ns.width ||
        contentRect.size.height != window->ns.height)
    {
        window->ns.width  = contentRect.size.width;
        window->ns.height = contentRect.size.height;
        _glfwInputWindowSize(window, contentRect.size.width, contentRect.size.height);
    }
}

- (void)windowDidMove:(NSNotification *)notification
{
    if (window->context.source == GLFW_NATIVE_CONTEXT_API)
        [window->context.nsgl.object update];

    if (_glfw.ns.disabledCursorWindow == window)
        _glfwCenterCursorInContentArea(window);

    int x, y;
    _glfwPlatformGetWindowPos(window, &x, &y);
    _glfwInputWindowPos(window, x, y);
}

- (void)windowDidMiniaturize:(NSNotification *)notification
{
    if (window->monitor)
        releaseMonitor(window);

    _glfwInputWindowIconify(window, GLFW_TRUE);
}

- (void)windowDidDeminiaturize:(NSNotification *)notification
{
    if (window->monitor)
        acquireMonitor(window);

    _glfwInputWindowIconify(window, GLFW_FALSE);
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    if (_glfw.ns.disabledCursorWindow == window)
        _glfwCenterCursorInContentArea(window);

    _glfwInputWindowFocus(window, GLFW_TRUE);
    updateCursorMode(window);
}

- (void)windowDidResignKey:(NSNotification *)notification
{
    if (window->monitor && window->autoIconify)
        _glfwPlatformIconifyWindow(window);

    _glfwInputWindowFocus(window, GLFW_FALSE);
}

- (void)windowDidChangeOcclusionState:(NSNotification* )notification
{
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1090
    if ([window->ns.object respondsToSelector:@selector(occlusionState)])
    {
        if ([window->ns.object occlusionState] & NSWindowOcclusionStateVisible)
            window->ns.occluded = GLFW_FALSE;
        else
            window->ns.occluded = GLFW_TRUE;
    }
#endif
}

@end


//------------------------------------------------------------------------
// Content view class for the GLFW window
//------------------------------------------------------------------------

@interface GLFWContentView : NSView <NSTextInputClient>
{
    _GLFWwindow* window;
    NSTrackingArea* trackingArea;
    NSMutableAttributedString* markedText;
}

- (instancetype)initWithGlfwWindow:(_GLFWwindow *)initWindow;

@end

@implementation GLFWContentView

- (instancetype)initWithGlfwWindow:(_GLFWwindow *)initWindow
{
    self = [super init];
    if (self != nil)
    {
        window = initWindow;
        trackingArea = nil;
        markedText = [[NSMutableAttributedString alloc] init];

        [self updateTrackingAreas];
        [self registerForDraggedTypes:@[NSPasteboardTypeURL]];
    }

    return self;
}

- (void)dealloc
{
    [trackingArea release];
    [markedText release];
    [super dealloc];
}

- (BOOL)isOpaque
{
    return [window->ns.object isOpaque];
}

- (BOOL)canBecomeKeyView
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    if (window->context.source == GLFW_NATIVE_CONTEXT_API)
        [window->context.nsgl.object update];

    _glfwInputWindowDamage(window);
}

- (void)cursorUpdate:(NSEvent *)event
{
    updateCursorImage(window);
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)mouseDown:(NSEvent *)event
{
    _glfwInputMouseClick(window,
                         GLFW_MOUSE_BUTTON_LEFT,
                         GLFW_PRESS,
                         translateFlags([event modifierFlags]));
}

- (void)mouseDragged:(NSEvent *)event
{
    [self mouseMoved:event];
}

- (void)mouseUp:(NSEvent *)event
{
    _glfwInputMouseClick(window,
                         GLFW_MOUSE_BUTTON_LEFT,
                         GLFW_RELEASE,
                         translateFlags([event modifierFlags]));
}

- (void)mouseMoved:(NSEvent *)event
{
    if (window->cursorMode == GLFW_CURSOR_DISABLED)
    {
        const double dx = [event deltaX] - window->ns.cursorWarpDeltaX;
        const double dy = [event deltaY] - window->ns.cursorWarpDeltaY;

        _glfwInputCursorPos(window,
                            window->virtualCursorPosX + dx,
                            window->virtualCursorPosY + dy);
    }
    else
    {
        const NSRect contentRect = [window->ns.view frame];
        // NOTE: The returned location uses base 0,1 not 0,0
        const NSPoint pos = [event locationInWindow];

        _glfwInputCursorPos(window, pos.x, contentRect.size.height - pos.y);
    }

    window->ns.cursorWarpDeltaX = 0;
    window->ns.cursorWarpDeltaY = 0;
}

- (void)rightMouseDown:(NSEvent *)event
{
    _glfwInputMouseClick(window,
                         GLFW_MOUSE_BUTTON_RIGHT,
                         GLFW_PRESS,
                         translateFlags([event modifierFlags]));
}

- (void)rightMouseDragged:(NSEvent *)event
{
    [self mouseMoved:event];
}

- (void)rightMouseUp:(NSEvent *)event
{
    _glfwInputMouseClick(window,
                         GLFW_MOUSE_BUTTON_RIGHT,
                         GLFW_RELEASE,
                         translateFlags([event modifierFlags]));
}

- (void)otherMouseDown:(NSEvent *)event
{
    _glfwInputMouseClick(window,
                         (int) [event buttonNumber],
                         GLFW_PRESS,
                         translateFlags([event modifierFlags]));
}

- (void)otherMouseDragged:(NSEvent *)event
{
    [self mouseMoved:event];
}

- (void)otherMouseUp:(NSEvent *)event
{
    _glfwInputMouseClick(window,
                         (int) [event buttonNumber],
                         GLFW_RELEASE,
                         translateFlags([event modifierFlags]));
}

- (void)mouseExited:(NSEvent *)event
{
    if (window->cursorMode == GLFW_CURSOR_HIDDEN)
        showCursor(window);

    _glfwInputCursorEnter(window, GLFW_FALSE);
}

- (void)mouseEntered:(NSEvent *)event
{
    if (window->cursorMode == GLFW_CURSOR_HIDDEN)
        hideCursor(window);

    _glfwInputCursorEnter(window, GLFW_TRUE);
}

- (void)viewDidChangeBackingProperties
{
    const NSRect contentRect = [window->ns.view frame];
    const NSRect fbRect = [window->ns.view convertRectToBacking:contentRect];
    const float xscale = fbRect.size.width / contentRect.size.width;
    const float yscale = fbRect.size.height / contentRect.size.height;

    if (xscale != window->ns.xscale || yscale != window->ns.yscale)
    {
        if (window->ns.retina && window->ns.layer)
            [window->ns.layer setContentsScale:[window->ns.object backingScaleFactor]];

        window->ns.xscale = xscale;
        window->ns.yscale = yscale;
        _glfwInputWindowContentScale(window, xscale, yscale);
    }

    if (fbRect.size.width != window->ns.fbWidth ||
        fbRect.size.height != window->ns.fbHeight)
    {
        window->ns.fbWidth  = fbRect.size.width;
        window->ns.fbHeight = fbRect.size.height;
        _glfwInputFramebufferSize(window, fbRect.size.width, fbRect.size.height);
    }
}

- (void)drawRect:(NSRect)rect
{
    _glfwInputWindowDamage(window);
}

- (void)updateTrackingAreas
{
    if (trackingArea != nil)
    {
        [self removeTrackingArea:trackingArea];
        [trackingArea release];
    }

    const NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited |
                                          NSTrackingActiveInKeyWindow |
                                          NSTrackingEnabledDuringMouseDrag |
                                          NSTrackingCursorUpdate |
                                          NSTrackingInVisibleRect |
                                          NSTrackingAssumeInside;

    trackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                                options:options
                                                  owner:self
                                               userInfo:nil];

    [self addTrackingArea:trackingArea];
    [super updateTrackingAreas];
}

- (void)keyDown:(NSEvent *)event
{
    const int key = translateKey([event keyCode]);
    const int mods = translateFlags([event modifierFlags]);

    _glfwInputKey(window, key, [event keyCode], GLFW_PRESS, mods);

    [self interpretKeyEvents:@[event]];
}

- (void)flagsChanged:(NSEvent *)event
{
    int action;
    const unsigned int modifierFlags =
        [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    const int key = translateKey([event keyCode]);
    const int mods = translateFlags(modifierFlags);
    const NSUInteger keyFlag = translateKeyToModifierFlag(key);

    if (keyFlag & modifierFlags)
    {
        if (window->keys[key] == GLFW_PRESS)
            action = GLFW_RELEASE;
        else
            action = GLFW_PRESS;
    }
    else
        action = GLFW_RELEASE;

    _glfwInputKey(window, key, [event keyCode], action, mods);
}

- (void)keyUp:(NSEvent *)event
{
    const int key = translateKey([event keyCode]);
    const int mods = translateFlags([event modifierFlags]);
    _glfwInputKey(window, key, [event keyCode], GLFW_RELEASE, mods);
}

- (void)scrollWheel:(NSEvent *)event
{
    double deltaX = [event scrollingDeltaX];
    double deltaY = [event scrollingDeltaY];

    if ([event hasPreciseScrollingDeltas])
    {
        deltaX *= 0.1;
        deltaY *= 0.1;
    }

    if (fabs(deltaX) > 0.0 || fabs(deltaY) > 0.0)
        _glfwInputScroll(window, deltaX, deltaY);
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    // HACK: We don't know what to say here because we don't know what the
    //       application wants to do with the paths
    return NSDragOperationGeneric;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    const NSRect contentRect = [window->ns.view frame];
    // NOTE: The returned location uses base 0,1 not 0,0
    const NSPoint pos = [sender draggingLocation];
    _glfwInputCursorPos(window, pos.x, contentRect.size.height - pos.y);

    NSPasteboard* pasteboard = [sender draggingPasteboard];
    NSDictionary* options = @{NSPasteboardURLReadingFileURLsOnlyKey:@YES};
    NSArray* urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                              options:options];
    const NSUInteger count = [urls count];
    if (count)
    {
        char** paths = calloc(count, sizeof(char*));

        for (NSUInteger i = 0;  i < count;  i++)
            paths[i] = _glfw_strdup([urls[i] fileSystemRepresentation]);

        _glfwInputDrop(window, (int) count, (const char**) paths);

        for (NSUInteger i = 0;  i < count;  i++)
            free(paths[i]);
        free(paths);
    }

    return YES;
}

- (BOOL)hasMarkedText
{
    return [markedText length] > 0;
}

- (NSRange)markedRange
{
    if ([markedText length] > 0)
        return NSMakeRange(0, [markedText length] - 1);
    else
        return kEmptyRange;
}

- (NSRange)selectedRange
{
    return kEmptyRange;
}

- (void)setMarkedText:(id)string
        selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange
{
    [markedText release];
    if ([string isKindOfClass:[NSAttributedString class]])
        markedText = [[NSMutableAttributedString alloc] initWithAttributedString:string];
    else
        markedText = [[NSMutableAttributedString alloc] initWithString:string];
}

- (void)unmarkText
{
    [[markedText mutableString] setString:@""];
}

- (NSArray*)validAttributesForMarkedText
{
    return [NSArray array];
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range
                                               actualRange:(NSRangePointer)actualRange
{
    return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    return 0;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actualRange
{
    const NSRect frame = [window->ns.view frame];
    return NSMakeRect(frame.origin.x, frame.origin.y, 0.0, 0.0);
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    NSString* characters;
    NSEvent* event = [NSApp currentEvent];
    const int mods = translateFlags([event modifierFlags]);
    const int plain = !(mods & GLFW_MOD_SUPER);

    if ([string isKindOfClass:[NSAttributedString class]])
        characters = [string string];
    else
        characters = (NSString*) string;

    NSRange range = NSMakeRange(0, [characters length]);
    while (range.length)
    {
        uint32_t codepoint = 0;

        if ([characters getBytes:&codepoint
                       maxLength:sizeof(codepoint)
                      usedLength:NULL
                        encoding:NSUTF32StringEncoding
                         options:0
                           range:range
                  remainingRange:&range])
        {
            if (codepoint >= 0xf700 && codepoint <= 0xf7ff)
                continue;

            _glfwInputChar(window, codepoint, mods, plain);
        }
    }
}

- (void)doCommandBySelector:(SEL)selector
{
}

@end


//------------------------------------------------------------------------
// GLFW window class
//------------------------------------------------------------------------

@interface GLFWWindow : NSWindow {}
@end

@implementation GLFWWindow

- (BOOL)canBecomeKeyWindow
{
    // Required for NSWindowStyleMaskBorderless windows
    return YES;
}

- (BOOL)canBecomeMainWindow
{
    return YES;
}

@end


// Create the Cocoa window
//
static GLFWbool createNativeWindow(_GLFWwindow* window,
                                   const _GLFWwndconfig* wndconfig,
                                   const _GLFWfbconfig* fbconfig)
{
    window->ns.delegate = [[GLFWWindowDelegate alloc] initWithGlfwWindow:window];
    if (window->ns.delegate == nil)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to create window delegate");
        return GLFW_FALSE;
    }

    NSRect contentRect;

    if (window->monitor)
    {
        GLFWvidmode mode;
        int xpos, ypos;

        _glfwPlatformGetVideoMode(window->monitor, &mode);
        _glfwPlatformGetMonitorPos(window->monitor, &xpos, &ypos);

        contentRect = NSMakeRect(xpos, ypos, mode.width, mode.height);
    }
    else
        contentRect = NSMakeRect(0, 0, wndconfig->width, wndconfig->height);

    NSUInteger styleMask = NSWindowStyleMaskMiniaturizable;

    if (window->monitor || !window->decorated)
        styleMask |= NSWindowStyleMaskBorderless;
    else
    {
        styleMask |= (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable);

        if (window->resizable)
            styleMask |= NSWindowStyleMaskResizable;
    }

    window->ns.object = [[GLFWWindow alloc]
        initWithContentRect:contentRect
                  styleMask:styleMask
                    backing:NSBackingStoreBuffered
                      defer:NO];

    if (window->ns.object == nil)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR, "Cocoa: Failed to create window");
        return GLFW_FALSE;
    }

    if (window->monitor)
        [window->ns.object setLevel:NSMainMenuWindowLevel + 1];
    else
    {
        [(NSWindow*) window->ns.object center];
        _glfw.ns.cascadePoint =
            NSPointToCGPoint([window->ns.object cascadeTopLeftFromPoint:
                              NSPointFromCGPoint(_glfw.ns.cascadePoint)]);

        if (wndconfig->resizable)
        {
            const NSWindowCollectionBehavior behavior =
                NSWindowCollectionBehaviorFullScreenPrimary |
                NSWindowCollectionBehaviorManaged;
            [window->ns.object setCollectionBehavior:behavior];
        }
        else
        {
            const NSWindowCollectionBehavior behavior =
                NSWindowCollectionBehaviorFullScreenNone;
            [window->ns.object setCollectionBehavior:behavior];
        }

        if (wndconfig->floating)
            [window->ns.object setLevel:NSStatusWindowLevel];

        if (wndconfig->maximized)
            [window->ns.object zoom:nil];
    }

    if (strlen(wndconfig->ns.frameName))
        [window->ns.object setFrameAutosaveName:@(wndconfig->ns.frameName)];

    window->ns.view = [[GLFWContentView alloc] initWithGlfwWindow:window];
    window->ns.retina = wndconfig->ns.retina;

    if (fbconfig->transparent)
    {
        [window->ns.object setOpaque:NO];
        [window->ns.object setHasShadow:NO];
        [window->ns.object setBackgroundColor:[NSColor clearColor]];
    }

    [window->ns.object setContentView:window->ns.view];
    [window->ns.object makeFirstResponder:window->ns.view];
    [window->ns.object setTitle:@(wndconfig->title)];
    [window->ns.object setDelegate:window->ns.delegate];
    [window->ns.object setAcceptsMouseMovedEvents:YES];
    [window->ns.object setRestorable:NO];

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101200
    if ([window->ns.object respondsToSelector:@selector(setTabbingMode:)])
        [window->ns.object setTabbingMode:NSWindowTabbingModeDisallowed];
#endif

    _glfwPlatformGetWindowSize(window, &window->ns.width, &window->ns.height);
    _glfwPlatformGetFramebufferSize(window, &window->ns.fbWidth, &window->ns.fbHeight);

    return GLFW_TRUE;
}


//////////////////////////////////////////////////////////////////////////
//////                       GLFW internal API                      //////
//////////////////////////////////////////////////////////////////////////

// Transforms a y-coordinate between the CG display and NS screen spaces
//
float _glfwTransformYNS(float y)
{
    return CGDisplayBounds(CGMainDisplayID()).size.height - y - 1;
}


//////////////////////////////////////////////////////////////////////////
//////                       GLFW platform API                      //////
//////////////////////////////////////////////////////////////////////////

int _glfwPlatformCreateWindow(_GLFWwindow* window,
                              const _GLFWwndconfig* wndconfig,
                              const _GLFWctxconfig* ctxconfig,
                              const _GLFWfbconfig* fbconfig)
{
    @autoreleasepool {

    if (!createNativeWindow(window, wndconfig, fbconfig))
        return GLFW_FALSE;

    if (ctxconfig->client != GLFW_NO_API)
    {
        if (ctxconfig->source == GLFW_NATIVE_CONTEXT_API)
        {
            if (!_glfwInitNSGL())
                return GLFW_FALSE;
            if (!_glfwCreateContextNSGL(window, ctxconfig, fbconfig))
                return GLFW_FALSE;
        }
        else if (ctxconfig->source == GLFW_EGL_CONTEXT_API)
        {
            // EGL implementation on macOS use CALayer* EGLNativeWindowType so we
            // need to get the layer for EGL window surface creation.
            [window->ns.view setWantsLayer:YES];
            window->ns.layer = [window->ns.view layer];

            if (!_glfwInitEGL())
                return GLFW_FALSE;
            if (!_glfwCreateContextEGL(window, ctxconfig, fbconfig))
                return GLFW_FALSE;
        }
        else if (ctxconfig->source == GLFW_OSMESA_CONTEXT_API)
        {
            if (!_glfwInitOSMesa())
                return GLFW_FALSE;
            if (!_glfwCreateContextOSMesa(window, ctxconfig, fbconfig))
                return GLFW_FALSE;
        }

        if (!_glfwRefreshContextAttribs(window, ctxconfig))
            return GLFW_FALSE;
    }

    if (wndconfig->mousePassthrough)
        _glfwPlatformSetWindowMousePassthrough(window, GLFW_TRUE);

    if (window->monitor)
    {
        _glfwPlatformShowWindow(window);
        _glfwPlatformFocusWindow(window);
        acquireMonitor(window);

        if (wndconfig->centerCursor)
            _glfwCenterCursorInContentArea(window);
    }
    else
    {
        if (wndconfig->visible)
        {
            _glfwPlatformShowWindow(window);
            if (wndconfig->focused)
                _glfwPlatformFocusWindow(window);
        }
    }

    return GLFW_TRUE;

    } // autoreleasepool
}

void _glfwPlatformDestroyWindow(_GLFWwindow* window)
{
    @autoreleasepool {

    if (_glfw.ns.disabledCursorWindow == window)
        _glfw.ns.disabledCursorWindow = NULL;

    [window->ns.object orderOut:nil];

    if (window->monitor)
        releaseMonitor(window);

    if (window->context.destroy)
        window->context.destroy(window);

    [window->ns.object setDelegate:nil];
    [window->ns.delegate release];
    window->ns.delegate = nil;

    [window->ns.view release];
    window->ns.view = nil;

    [window->ns.object close];
    window->ns.object = nil;

    // HACK: Allow Cocoa to catch up before returning
    _glfwPlatformPollEvents();

    } // autoreleasepool
}

void _glfwPlatformSetWindowTitle(_GLFWwindow* window, const char* title)
{
    @autoreleasepool {
    NSString* string = @(title);
    [window->ns.object setTitle:string];
    // HACK: Set the miniwindow title explicitly as setTitle: doesn't update it
    //       if the window lacks NSWindowStyleMaskTitled
    [window->ns.object setMiniwindowTitle:string];
    } // autoreleasepool
}

void _glfwPlatformSetWindowIcon(_GLFWwindow* window,
                                int count, const GLFWimage* images)
{
    // Regular windows do not have icons
}

void _glfwPlatformGetWindowPos(_GLFWwindow* window, int* xpos, int* ypos)
{
    @autoreleasepool {

    const NSRect contentRect =
        [window->ns.object contentRectForFrameRect:[window->ns.object frame]];

    if (xpos)
        *xpos = contentRect.origin.x;
    if (ypos)
        *ypos = _glfwTransformYNS(contentRect.origin.y + contentRect.size.height - 1);

    } // autoreleasepool
}

void _glfwPlatformSetWindowPos(_GLFWwindow* window, int x, int y)
{
    @autoreleasepool {

    const NSRect contentRect = [window->ns.view frame];
    const NSRect dummyRect = NSMakeRect(x, _glfwTransformYNS(y + contentRect.size.height - 1), 0, 0);
    const NSRect frameRect = [window->ns.object frameRectForContentRect:dummyRect];
    [window->ns.object setFrameOrigin:frameRect.origin];

    } // autoreleasepool
}

void _glfwPlatformGetWindowSize(_GLFWwindow* window, int* width, int* height)
{
    @autoreleasepool {

    const NSRect contentRect = [window->ns.view frame];

    if (width)
        *width = contentRect.size.width;
    if (height)
        *height = contentRect.size.height;

    } // autoreleasepool
}

void _glfwPlatformSetWindowSize(_GLFWwindow* window, int width, int height)
{
    @autoreleasepool {

    if (window->monitor)
    {
        if (window->monitor->window == window)
            acquireMonitor(window);
    }
    else
    {
        NSRect contentRect =
            [window->ns.object contentRectForFrameRect:[window->ns.object frame]];
        contentRect.origin.y += contentRect.size.height - height;
        contentRect.size = NSMakeSize(width, height);
        [window->ns.object setFrame:[window->ns.object frameRectForContentRect:contentRect]
                            display:YES];
    }

    } // autoreleasepool
}

void _glfwPlatformSetWindowSizeLimits(_GLFWwindow* window,
                                      int minwidth, int minheight,
                                      int maxwidth, int maxheight)
{
    @autoreleasepool {

    if (minwidth == GLFW_DONT_CARE || minheight == GLFW_DONT_CARE)
        [window->ns.object setContentMinSize:NSMakeSize(0, 0)];
    else
        [window->ns.object setContentMinSize:NSMakeSize(minwidth, minheight)];

    if (maxwidth == GLFW_DONT_CARE || maxheight == GLFW_DONT_CARE)
        [window->ns.object setContentMaxSize:NSMakeSize(DBL_MAX, DBL_MAX)];
    else
        [window->ns.object setContentMaxSize:NSMakeSize(maxwidth, maxheight)];

    } // autoreleasepool
}

void _glfwPlatformSetWindowAspectRatio(_GLFWwindow* window, int numer, int denom)
{
    @autoreleasepool {
    if (numer == GLFW_DONT_CARE || denom == GLFW_DONT_CARE)
        [window->ns.object setResizeIncrements:NSMakeSize(1.0, 1.0)];
    else
        [window->ns.object setContentAspectRatio:NSMakeSize(numer, denom)];
    } // autoreleasepool
}

void _glfwPlatformGetFramebufferSize(_GLFWwindow* window, int* width, int* height)
{
    @autoreleasepool {

    const NSRect contentRect = [window->ns.view frame];
    const NSRect fbRect = [window->ns.view convertRectToBacking:contentRect];

    if (width)
        *width = (int) fbRect.size.width;
    if (height)
        *height = (int) fbRect.size.height;

    } // autoreleasepool
}

void _glfwPlatformGetWindowFrameSize(_GLFWwindow* window,
                                     int* left, int* top,
                                     int* right, int* bottom)
{
    @autoreleasepool {

    const NSRect contentRect = [window->ns.view frame];
    const NSRect frameRect = [window->ns.object frameRectForContentRect:contentRect];

    if (left)
        *left = contentRect.origin.x - frameRect.origin.x;
    if (top)
        *top = frameRect.origin.y + frameRect.size.height -
               contentRect.origin.y - contentRect.size.height;
    if (right)
        *right = frameRect.origin.x + frameRect.size.width -
                 contentRect.origin.x - contentRect.size.width;
    if (bottom)
        *bottom = contentRect.origin.y - frameRect.origin.y;

    } // autoreleasepool
}

void _glfwPlatformGetWindowContentScale(_GLFWwindow* window,
                                        float* xscale, float* yscale)
{
    @autoreleasepool {

    const NSRect points = [window->ns.view frame];
    const NSRect pixels = [window->ns.view convertRectToBacking:points];

    if (xscale)
        *xscale = (float) (pixels.size.width / points.size.width);
    if (yscale)
        *yscale = (float) (pixels.size.height / points.size.height);

    } // autoreleasepool
}

void _glfwPlatformIconifyWindow(_GLFWwindow* window)
{
    @autoreleasepool {
    [window->ns.object miniaturize:nil];
    } // autoreleasepool
}

void _glfwPlatformRestoreWindow(_GLFWwindow* window)
{
    @autoreleasepool {
    if ([window->ns.object isMiniaturized])
        [window->ns.object deminiaturize:nil];
    else if ([window->ns.object isZoomed])
        [window->ns.object zoom:nil];
    } // autoreleasepool
}

void _glfwPlatformMaximizeWindow(_GLFWwindow* window)
{
    @autoreleasepool {
    if (![window->ns.object isZoomed])
        [window->ns.object zoom:nil];
    } // autoreleasepool
}

void _glfwPlatformShowWindow(_GLFWwindow* window)
{
    @autoreleasepool {
    [window->ns.object orderFront:nil];
    } // autoreleasepool
}

void _glfwPlatformHideWindow(_GLFWwindow* window)
{
    @autoreleasepool {
    [window->ns.object orderOut:nil];
    } // autoreleasepool
}

void _glfwPlatformRequestWindowAttention(_GLFWwindow* window)
{
    @autoreleasepool {
    [NSApp requestUserAttention:NSInformationalRequest];
    } // autoreleasepool
}

void _glfwPlatformFocusWindow(_GLFWwindow* window)
{
    @autoreleasepool {
    // Make us the active application
    // HACK: This is here to prevent applications using only hidden windows from
    //       being activated, but should probably not be done every time any
    //       window is shown
    [NSApp activateIgnoringOtherApps:YES];
    [window->ns.object makeKeyAndOrderFront:nil];
    } // autoreleasepool
}

void _glfwPlatformSetWindowMonitor(_GLFWwindow* window,
                                   _GLFWmonitor* monitor,
                                   int xpos, int ypos,
                                   int width, int height,
                                   int refreshRate)
{
    @autoreleasepool {

    if (window->monitor == monitor)
    {
        if (monitor)
        {
            if (monitor->window == window)
                acquireMonitor(window);
        }
        else
        {
            const NSRect contentRect =
                NSMakeRect(xpos, _glfwTransformYNS(ypos + height - 1), width, height);
            const NSUInteger styleMask = [window->ns.object styleMask];
            const NSRect frameRect =
                [window->ns.object frameRectForContentRect:contentRect
                                                 styleMask:styleMask];

            [window->ns.object setFrame:frameRect display:YES];
        }

        return;
    }

    if (window->monitor)
        releaseMonitor(window);

    _glfwInputWindowMonitor(window, monitor);

    // HACK: Allow the state cached in Cocoa to catch up to reality
    // TODO: Solve this in a less terrible way
    _glfwPlatformPollEvents();

    NSUInteger styleMask = [window->ns.object styleMask];

    if (window->monitor)
    {
        styleMask &= ~(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable);
        styleMask |= NSWindowStyleMaskBorderless;
    }
    else
    {
        if (window->decorated)
        {
            styleMask &= ~NSWindowStyleMaskBorderless;
            styleMask |= (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable);
        }

        if (window->resizable)
            styleMask |= NSWindowStyleMaskResizable;
        else
            styleMask &= ~NSWindowStyleMaskResizable;
    }

    [window->ns.object setStyleMask:styleMask];
    // HACK: Changing the style mask can cause the first responder to be cleared
    [window->ns.object makeFirstResponder:window->ns.view];

    if (window->monitor)
    {
        [window->ns.object setLevel:NSMainMenuWindowLevel + 1];
        [window->ns.object setHasShadow:NO];

        acquireMonitor(window);
    }
    else
    {
        NSRect contentRect = NSMakeRect(xpos, _glfwTransformYNS(ypos + height - 1),
                                        width, height);
        NSRect frameRect = [window->ns.object frameRectForContentRect:contentRect
                                                            styleMask:styleMask];
        [window->ns.object setFrame:frameRect display:YES];

        if (window->numer != GLFW_DONT_CARE &&
            window->denom != GLFW_DONT_CARE)
        {
            [window->ns.object setContentAspectRatio:NSMakeSize(window->numer,
                                                                window->denom)];
        }

        if (window->minwidth != GLFW_DONT_CARE &&
            window->minheight != GLFW_DONT_CARE)
        {
            [window->ns.object setContentMinSize:NSMakeSize(window->minwidth,
                                                            window->minheight)];
        }

        if (window->maxwidth != GLFW_DONT_CARE &&
            window->maxheight != GLFW_DONT_CARE)
        {
            [window->ns.object setContentMaxSize:NSMakeSize(window->maxwidth,
                                                            window->maxheight)];
        }

        if (window->floating)
            [window->ns.object setLevel:NSStatusWindowLevel];
        else
            [window->ns.object setLevel:NSNormalWindowLevel];

        if (window->resizable)
        {
            const NSWindowCollectionBehavior behavior =
                NSWindowCollectionBehaviorFullScreenPrimary |
                NSWindowCollectionBehaviorManaged;
            [window->ns.object setCollectionBehavior:behavior];
        }
        else
        {
            const NSWindowCollectionBehavior behavior =
                NSWindowCollectionBehaviorFullScreenNone;
            [window->ns.object setCollectionBehavior:behavior];
        }

        [window->ns.object setHasShadow:YES];
        // HACK: Clearing NSWindowStyleMaskTitled resets and disables the window
        //       title property but the miniwindow title property is unaffected
        [window->ns.object setTitle:[window->ns.object miniwindowTitle]];
    }

    } // autoreleasepool
}

int _glfwPlatformWindowFocused(_GLFWwindow* window)
{
    @autoreleasepool {
    return [window->ns.object isKeyWindow];
    } // autoreleasepool
}

int _glfwPlatformWindowIconified(_GLFWwindow* window)
{
    @autoreleasepool {
    return [window->ns.object isMiniaturized];
    } // autoreleasepool
}

int _glfwPlatformWindowVisible(_GLFWwindow* window)
{
    @autoreleasepool {
    return [window->ns.object isVisible];
    } // autoreleasepool
}

int _glfwPlatformWindowMaximized(_GLFWwindow* window)
{
    @autoreleasepool {

    if (window->resizable)
        return [window->ns.object isZoomed];
    else
        return GLFW_FALSE;

    } // autoreleasepool
}

int _glfwPlatformWindowHovered(_GLFWwindow* window)
{
    @autoreleasepool {

    const NSPoint point = [NSEvent mouseLocation];

    if ([NSWindow windowNumberAtPoint:point belowWindowWithWindowNumber:0] !=
        [window->ns.object windowNumber])
    {
        return GLFW_FALSE;
    }

    return NSMouseInRect(point,
        [window->ns.object convertRectToScreen:[window->ns.view frame]], NO);

    } // autoreleasepool
}

int _glfwPlatformFramebufferTransparent(_GLFWwindow* window)
{
    @autoreleasepool {
    return ![window->ns.object isOpaque] && ![window->ns.view isOpaque];
    } // autoreleasepool
}

void _glfwPlatformSetWindowResizable(_GLFWwindow* window, GLFWbool enabled)
{
    @autoreleasepool {

    const NSUInteger styleMask = [window->ns.object styleMask];
    if (enabled)
    {
        [window->ns.object setStyleMask:(styleMask | NSWindowStyleMaskResizable)];
        const NSWindowCollectionBehavior behavior =
            NSWindowCollectionBehaviorFullScreenPrimary |
            NSWindowCollectionBehaviorManaged;
        [window->ns.object setCollectionBehavior:behavior];
    }
    else
    {
        [window->ns.object setStyleMask:(styleMask & ~NSWindowStyleMaskResizable)];
        const NSWindowCollectionBehavior behavior =
            NSWindowCollectionBehaviorFullScreenNone;
        [window->ns.object setCollectionBehavior:behavior];
    }

    } // autoreleasepool
}

void _glfwPlatformSetWindowDecorated(_GLFWwindow* window, GLFWbool enabled)
{
    @autoreleasepool {

    NSUInteger styleMask = [window->ns.object styleMask];
    if (enabled)
    {
        styleMask |= (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable);
        styleMask &= ~NSWindowStyleMaskBorderless;
    }
    else
    {
        styleMask |= NSWindowStyleMaskBorderless;
        styleMask &= ~(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable);
    }

    [window->ns.object setStyleMask:styleMask];
    [window->ns.object makeFirstResponder:window->ns.view];

    } // autoreleasepool
}

void _glfwPlatformSetWindowFloating(_GLFWwindow* window, GLFWbool enabled)
{
    @autoreleasepool {
    if (enabled)
        [window->ns.object setLevel:NSStatusWindowLevel];
    else
        [window->ns.object setLevel:NSNormalWindowLevel];
    } // autoreleasepool
}

void _glfwPlatformSetWindowMousePassthrough(_GLFWwindow* window, GLFWbool enabled)
{
    @autoreleasepool {
    [window->ns.object setIgnoresMouseEvents:enabled];
    }
}

float _glfwPlatformGetWindowOpacity(_GLFWwindow* window)
{
    @autoreleasepool {
    return (float) [window->ns.object alphaValue];
    } // autoreleasepool
}

void _glfwPlatformSetWindowOpacity(_GLFWwindow* window, float opacity)
{
    @autoreleasepool {
    [window->ns.object setAlphaValue:opacity];
    } // autoreleasepool
}

void _glfwPlatformSetRawMouseMotion(_GLFWwindow *window, GLFWbool enabled)
{
}

GLFWbool _glfwPlatformRawMouseMotionSupported(void)
{
    return GLFW_FALSE;
}

void _glfwPlatformPollEvents(void)
{
    @autoreleasepool {

    for (;;)
    {
        NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate distantPast]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES];
        if (event == nil)
            break;

        [NSApp sendEvent:event];
    }

    } // autoreleasepool
}

void _glfwPlatformWaitEvents(void)
{
    @autoreleasepool {

    // I wanted to pass NO to dequeue:, and rely on PollEvents to
    // dequeue and send.  For reasons not at all clear to me, passing
    // NO to dequeue: causes this method never to return.
    NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:[NSDate distantFuture]
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
    [NSApp sendEvent:event];

    _glfwPlatformPollEvents();

    } // autoreleasepool
}

void _glfwPlatformWaitEventsTimeout(double timeout)
{
    @autoreleasepool {

    NSDate* date = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:date
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
    if (event)
        [NSApp sendEvent:event];

    _glfwPlatformPollEvents();

    } // autoreleasepool
}

void _glfwPlatformPostEmptyEvent(void)
{
    @autoreleasepool {

    NSEvent* event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSMakePoint(0, 0)
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0];
    [NSApp postEvent:event atStart:YES];

    } // autoreleasepool
}

void _glfwPlatformGetCursorPos(_GLFWwindow* window, double* xpos, double* ypos)
{
    @autoreleasepool {

    const NSRect contentRect = [window->ns.view frame];
    // NOTE: The returned location uses base 0,1 not 0,0
    const NSPoint pos = [window->ns.object mouseLocationOutsideOfEventStream];

    if (xpos)
        *xpos = pos.x;
    if (ypos)
        *ypos = contentRect.size.height - pos.y;

    } // autoreleasepool
}

void _glfwPlatformSetCursorPos(_GLFWwindow* window, double x, double y)
{
    @autoreleasepool {

    updateCursorImage(window);

    const NSRect contentRect = [window->ns.view frame];
    // NOTE: The returned location uses base 0,1 not 0,0
    const NSPoint pos = [window->ns.object mouseLocationOutsideOfEventStream];

    window->ns.cursorWarpDeltaX += x - pos.x;
    window->ns.cursorWarpDeltaY += y - contentRect.size.height + pos.y;

    if (window->monitor)
    {
        CGDisplayMoveCursorToPoint(window->monitor->ns.displayID,
                                   CGPointMake(x, y));
    }
    else
    {
        const NSRect localRect = NSMakeRect(x, contentRect.size.height - y - 1, 0, 0);
        const NSRect globalRect = [window->ns.object convertRectToScreen:localRect];
        const NSPoint globalPoint = globalRect.origin;

        CGWarpMouseCursorPosition(CGPointMake(globalPoint.x,
                                              _glfwTransformYNS(globalPoint.y)));
    }

    // HACK: Calling this right after setting the cursor position prevents macOS
    //       from freezing the cursor for a fraction of a second afterwards
    if (window->cursorMode != GLFW_CURSOR_DISABLED)
        CGAssociateMouseAndMouseCursorPosition(true);

    } // autoreleasepool
}

void _glfwPlatformSetCursorMode(_GLFWwindow* window, int mode)
{
    @autoreleasepool {
    if (_glfwPlatformWindowFocused(window))
        updateCursorMode(window);
    } // autoreleasepool
}

const char* _glfwPlatformGetScancodeName(int scancode)
{
    @autoreleasepool {

    if (scancode < 0 || scancode > 0xff)
    {
        _glfwInputError(GLFW_INVALID_VALUE, "Invalid scancode %i", scancode);
        return NULL;
    }

    const int key = _glfw.ns.keycodes[scancode];
    if (key == GLFW_KEY_UNKNOWN)
        return NULL;

    UInt32 deadKeyState = 0;
    UniChar characters[4];
    UniCharCount characterCount = 0;

    if (UCKeyTranslate([(NSData*) _glfw.ns.unicodeData bytes],
                       scancode,
                       kUCKeyActionDisplay,
                       0,
                       LMGetKbdType(),
                       kUCKeyTranslateNoDeadKeysBit,
                       &deadKeyState,
                       sizeof(characters) / sizeof(characters[0]),
                       &characterCount,
                       characters) != noErr)
    {
        return NULL;
    }

    if (!characterCount)
        return NULL;

    CFStringRef string = CFStringCreateWithCharactersNoCopy(kCFAllocatorDefault,
                                                            characters,
                                                            characterCount,
                                                            kCFAllocatorNull);
    CFStringGetCString(string,
                       _glfw.ns.keynames[key],
                       sizeof(_glfw.ns.keynames[key]),
                       kCFStringEncodingUTF8);
    CFRelease(string);

    return _glfw.ns.keynames[key];

    } // autoreleasepool
}

int _glfwPlatformGetKeyScancode(int key)
{
    return _glfw.ns.scancodes[key];
}

int _glfwPlatformCreateCursor(_GLFWcursor* cursor,
                              const GLFWimage* image,
                              int xhot, int yhot)
{
    @autoreleasepool {

    NSImage* native;
    NSBitmapImageRep* rep;

    rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:image->width
                      pixelsHigh:image->height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                    bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                     bytesPerRow:image->width * 4
                    bitsPerPixel:32];

    if (rep == nil)
        return GLFW_FALSE;

    memcpy([rep bitmapData], image->pixels, image->width * image->height * 4);

    native = [[NSImage alloc] initWithSize:NSMakeSize(image->width, image->height)];
    [native addRepresentation:rep];

    cursor->ns.object = [[NSCursor alloc] initWithImage:native
                                                hotSpot:NSMakePoint(xhot, yhot)];

    [native release];
    [rep release];

    if (cursor->ns.object == nil)
        return GLFW_FALSE;

    return GLFW_TRUE;

    } // autoreleasepool
}

int _glfwPlatformCreateStandardCursor(_GLFWcursor* cursor, int shape)
{
    @autoreleasepool {

    SEL cursorSelector = NULL;

    switch (shape)
    {
        case GLFW_HRESIZE_CURSOR:
            cursorSelector = NSSelectorFromString(@"_windowResizeEastWestCursor");
            break;
        case GLFW_VRESIZE_CURSOR:
            cursorSelector = NSSelectorFromString(@"_windowResizeNorthSouthCursor");
            break;
        case GLFW_RESIZE_NWSE_CURSOR:
            cursorSelector = NSSelectorFromString(@"_windowResizeNorthWestSouthEastCursor");
            break;
        case GLFW_RESIZE_NESW_CURSOR:
            cursorSelector = NSSelectorFromString(@"_windowResizeNorthEastSouthWestCursor");
            break;
    }

    if (cursorSelector && [NSCursor respondsToSelector:cursorSelector])
    {
        id object = [NSCursor performSelector:cursorSelector];
        if ([object isKindOfClass:[NSCursor class]])
            cursor->ns.object = object;
    }

    if (!cursor->ns.object)
    {
        switch (shape)
        {
            case GLFW_ARROW_CURSOR:
                cursor->ns.object = [NSCursor arrowCursor];
                break;
            case GLFW_IBEAM_CURSOR:
                cursor->ns.object = [NSCursor IBeamCursor];
                break;
            case GLFW_CROSSHAIR_CURSOR:
                cursor->ns.object = [NSCursor crosshairCursor];
                break;
            case GLFW_HAND_CURSOR:
                cursor->ns.object = [NSCursor pointingHandCursor];
                break;
            case GLFW_RESIZE_ALL_CURSOR:
            {
                // Use the OS's resource: https://stackoverflow.com/a/21786835/5435443
                NSString *cursorName = @"move";
                NSString *cursorPath = [@"/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors" stringByAppendingPathComponent:cursorName];
                NSImage *image = [[NSImage alloc] initByReferencingFile:[cursorPath stringByAppendingPathComponent:@"cursor.pdf"]];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[cursorPath stringByAppendingPathComponent:@"info.plist"]];
                cursor->ns.object = [[NSCursor alloc] initWithImage:image
                                                            hotSpot:NSMakePoint([[info valueForKey:@"hotx"] doubleValue],
                                                                                [[info valueForKey:@"hoty"] doubleValue])];
                break;
            }
            case GLFW_NOT_ALLOWED_CURSOR:
                cursor->ns.object = [NSCursor operationNotAllowedCursor];
                break;
        }
    }

    if (!cursor->ns.object)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to retrieve standard cursor");
        return GLFW_FALSE;
    }

    [cursor->ns.object retain];
    return GLFW_TRUE;

    } // autoreleasepool
}

void _glfwPlatformDestroyCursor(_GLFWcursor* cursor)
{
    @autoreleasepool {
    if (cursor->ns.object)
        [(NSCursor*) cursor->ns.object release];
    } // autoreleasepool
}

void _glfwPlatformSetCursor(_GLFWwindow* window, _GLFWcursor* cursor)
{
    @autoreleasepool {
    if (cursorInContentArea(window))
        updateCursorImage(window);
    } // autoreleasepool
}

void _glfwPlatformSetClipboardString(const char* string)
{
    @autoreleasepool {
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
    [pasteboard setString:@(string) forType:NSPasteboardTypeString];
    } // autoreleasepool
}

const char* _glfwPlatformGetClipboardString(void)
{
    @autoreleasepool {

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];

    if (![[pasteboard types] containsObject:NSPasteboardTypeString])
    {
        _glfwInputError(GLFW_FORMAT_UNAVAILABLE,
                        "Cocoa: Failed to retrieve string from pasteboard");
        return NULL;
    }

    NSString* object = [pasteboard stringForType:NSPasteboardTypeString];
    if (!object)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to retrieve object from pasteboard");
        return NULL;
    }

    free(_glfw.ns.clipboardString);
    _glfw.ns.clipboardString = _glfw_strdup([object UTF8String]);

    return _glfw.ns.clipboardString;

    } // autoreleasepool
}


//////////////////////////////////////////////////////////////////////////
//////                        GLFW native API                       //////
//////////////////////////////////////////////////////////////////////////

GLFWAPI id glfwGetCocoaWindow(GLFWwindow* handle)
{
    _GLFWwindow* window = (_GLFWwindow*) handle;
    _GLFW_REQUIRE_INIT_OR_RETURN(nil);
    return window->ns.object;
}

