/////////////////////////////////////////////////////////////////////////////
// Name:        src/osx/cocoa/window.mm
// Purpose:     widgets (non tlw) for cocoa
// Author:      Stefan Csomor
// Modified by:
// Created:     2008-06-20
// Copyright:   (c) Stefan Csomor
// Licence:     wxWindows licence
/////////////////////////////////////////////////////////////////////////////

#include "wx/wxprec.h"

#ifndef WX_PRECOMP
    #include "wx/dcclient.h"
    #include "wx/frame.h"
    #include "wx/log.h"
    #include "wx/textctrl.h"
    #include "wx/combobox.h"
    #include "wx/radiobut.h"
    #include "wx/button.h"
    #include "wx/hashset.h"
#endif

#ifdef __WXMAC__
    #include "wx/osx/private.h"
#endif

#include "wx/evtloop.h"

#if wxUSE_CARET
    #include "wx/caret.h"
#endif

#if wxUSE_DRAG_AND_DROP
    #include "wx/dnd.h"
#endif

#if wxUSE_TOOLTIPS
    #include "wx/tooltip.h"
#endif

#include <objc/objc-runtime.h>
#include "wx/cocoa/string.h"

// Get the window with the focus

NSView* wxOSXGetViewFromResponder( NSResponder* responder )
{
    NSView* view = nil;
    if ( [responder isKindOfClass:[NSTextView class]] )
    {
        NSView* delegate = (NSView*) [(NSTextView*)responder delegate];
        if ( [delegate isKindOfClass:[NSTextField class] ] )
            view = delegate;
        else
            view =  (NSView*) responder;
    }
    else
    {
        if ( [responder isKindOfClass:[NSView class]] )
            view = (NSView*) responder;
    }
    return view;
}

NSView* GetFocusedViewInWindow( NSWindow* keyWindow )
{
    NSView* focusedView = nil;
    if ( keyWindow != nil )
        focusedView = wxOSXGetViewFromResponder([keyWindow firstResponder]);

    return focusedView;
}

WXWidget wxWidgetImpl::FindFocus()
{
    return GetFocusedViewInWindow( [NSApp keyWindow] );;
}

wxWidgetImpl* wxWidgetImpl::FindBestFromWXWidget(WXWidget control)
{
    wxWidgetImpl* impl = FindFromWXWidget(control);
    
    // NSScrollViews can have their subviews like NSClipView
    // therefore check and use the NSScrollView peer in that case
    if ( impl == NULL && [[control superview] isKindOfClass:[NSScrollView class]])
        impl = FindFromWXWidget([control superview]);
    
    return impl;
}


NSRect wxOSXGetFrameForControl( wxWindowMac* window , const wxPoint& pos , const wxSize &size , bool adjustForOrigin )
{
    int x, y, w, h ;

    window->MacGetBoundsForControl( pos , size , x , y, w, h , adjustForOrigin ) ;
    wxRect bounds(x,y,w,h);
    NSView* sv = (window->GetParent()->GetHandle() );

    return wxToNSRect( sv, bounds );
}

@interface wxNSView : NSView
{
    BOOL _hasToolTip;    
    NSTrackingRectTag   _lastToolTipTrackTag;
    id              _lastToolTipOwner;
    void*           _lastUserData;
    
}

@end // wxNSView

@interface wxNSView(TextInput) <NSTextInputClient>

- (void)insertText:(id)aString replacementRange:(NSRange)replacementRange;
- (void)doCommandBySelector:(SEL)aSelector;
- (void)setMarkedText:(id)aString selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange;
- (void)unmarkText;
- (NSRange)selectedRange;
- (NSRange)markedRange;
- (BOOL)hasMarkedText;
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)aRange actualRange:(NSRangePointer)actualRange;
- (NSArray*)validAttributesForMarkedText;
- (NSRect)firstRectForCharacterRange:(NSRange)aRange actualRange:(NSRangePointer)actualRange;
- (NSUInteger)characterIndexForPoint:(NSPoint)aPoint;

@end

@interface NSView(PossibleMethods)
- (void)setTitle:(NSString *)aString;
- (void)setStringValue:(NSString *)aString;
- (void)setIntValue:(int)anInt;
- (void)setFloatValue:(float)aFloat;
- (void)setDoubleValue:(double)aDouble;

- (double)minValue;
- (double)maxValue;
- (void)setMinValue:(double)aDouble;
- (void)setMaxValue:(double)aDouble;

- (void)sizeToFit;

- (BOOL)isEnabled;
- (void)setEnabled:(BOOL)flag;

- (void)setImage:(NSImage *)image;
- (void)setControlSize:(NSControlSize)size;

- (void)setFont:(NSFont *)fontObject;

- (id)contentView;

- (void)setTarget:(id)anObject;
- (void)setAction:(SEL)aSelector;
- (void)setDoubleAction:(SEL)aSelector;
- (void)setBackgroundColor:(NSColor*)aColor;
- (void)setOpaque:(BOOL)opaque;
- (void)setTextColor:(NSColor *)color;
- (void)setImagePosition:(NSCellImagePosition)aPosition;
@end

// The following code is a combination of the code listed here:
// http://lists.apple.com/archives/cocoa-dev/2008/Apr/msg01582.html
// (which can't be used because KLGetCurrentKeyboardLayout etc aren't 64-bit)
// and the code here:
// http://inquisitivecocoa.com/category/objective-c/
@interface NSEvent (OsGuiUtilsAdditions)
- (NSString*) charactersIgnoringModifiersIncludingShift;
@end

@implementation NSEvent (OsGuiUtilsAdditions)
- (NSString*) charactersIgnoringModifiersIncludingShift {
    // First try -charactersIgnoringModifiers and look for keys which UCKeyTranslate translates
    // differently than AppKit.
    NSString* c = [self charactersIgnoringModifiers];
    if ([c length] == 1) {
        unichar codepoint = [c characterAtIndex:0];
        if ((codepoint >= 0xF700 && codepoint <= 0xF8FF) || codepoint == 0x7F) {
            return c;
        }
    }
    // This is not a "special" key, so ask UCKeyTranslate to give us the character with no
    // modifiers attached.  Actually, that's not quite accurate; we attach the Command modifier
    // which hints the OS to use Latin characters where possible, which is generally what we want.
    NSString* result = @"";
    TISInputSourceRef currentKeyboard = TISCopyCurrentKeyboardInputSource();
    CFDataRef uchr = (CFDataRef)TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData);
    CFRelease(currentKeyboard);
    if (uchr == NULL) {
        // this can happen for some non-U.S. input methods (eg. Romaji or Hiragana)
        return c;
    }
    const UCKeyboardLayout *keyboardLayout = (const UCKeyboardLayout*)CFDataGetBytePtr(uchr);
    if (keyboardLayout) {
        UInt32 deadKeyState = 0;
        const UniCharCount maxStringLength = 255;
        UniCharCount actualStringLength = 0;
        UniChar unicodeString[maxStringLength];
        
        OSStatus status = UCKeyTranslate(keyboardLayout,
                                         [self keyCode],
                                         kUCKeyActionDown,
                                         cmdKey >> 8,         // force the Command key to "on"
                                         LMGetKbdType(),
                                         kUCKeyTranslateNoDeadKeysMask,
                                         &deadKeyState,
                                         maxStringLength,
                                         &actualStringLength,
                                         unicodeString);
        
        if(status == noErr)
            result = [NSString stringWithCharacters:unicodeString length:(NSInteger)actualStringLength];
    }
    return result;
}
@end

long wxOSXTranslateCocoaKey( NSEvent* event, int eventType )
{
    long retval = 0;

    if ([event type] != NSFlagsChanged)
    {
        NSString* s = [event charactersIgnoringModifiersIncludingShift];
        // backspace char reports as delete w/modifiers for some reason
        if ([s length] == 1)
        {
            if ( eventType == wxEVT_CHAR && ([event modifierFlags] & NSControlKeyMask) && ( [s characterAtIndex:0] >= 'a' && [s characterAtIndex:0] <= 'z' ) )
            {
                retval = WXK_CONTROL_A + ([s characterAtIndex:0] - 'a');
            }
            else
            {
                switch ( [s characterAtIndex:0] )
                {
                    // numpad enter key End-of-text character ETX U+0003
                    case 3:
                        retval = WXK_NUMPAD_ENTER;
                        break;
                    // backspace key
                    case 0x7F :
                    case 8 :
                        retval = WXK_BACK;
                        break;
                    case NSUpArrowFunctionKey :
                        retval = WXK_UP;
                        break;
                    case NSDownArrowFunctionKey :
                        retval = WXK_DOWN;
                        break;
                    case NSLeftArrowFunctionKey :
                        retval = WXK_LEFT;
                        break;
                    case NSRightArrowFunctionKey :
                        retval = WXK_RIGHT;
                        break;
                    case NSInsertFunctionKey  :
                        retval = WXK_INSERT;
                        break;
                    case NSDeleteFunctionKey  :
                        retval = WXK_DELETE;
                        break;
                    case NSHomeFunctionKey  :
                        retval = WXK_HOME;
                        break;
            //        case NSBeginFunctionKey  :
            //            retval = WXK_BEGIN;
            //            break;
                    case NSEndFunctionKey  :
                        retval = WXK_END;
                        break;
                    case NSPageUpFunctionKey  :
                        retval = WXK_PAGEUP;
                        break;
                   case NSPageDownFunctionKey  :
                        retval = WXK_PAGEDOWN;
                        break;
                   case NSHelpFunctionKey  :
                        retval = WXK_HELP;
                        break;
                    default:
                        int intchar = [s characterAtIndex: 0];
                        if ( intchar >= NSF1FunctionKey && intchar <= NSF24FunctionKey )
                            retval = WXK_F1 + (intchar - NSF1FunctionKey );
                        else if ( intchar > 0 && intchar < 32 )
                            retval = intchar;
                        break;
                }
            }
        }
    }

    // Some keys don't seem to have constants. The code mimics the approach
    // taken by WebKit. See:
    // http://trac.webkit.org/browser/trunk/WebCore/platform/mac/KeyEventMac.mm
    switch( [event keyCode] )
    {
        // command key
        case 54:
        case 55:
            retval = WXK_CONTROL;
            break;
        // caps locks key
        case 57: // Capslock
            retval = WXK_CAPITAL;
            break;
        // shift key
        case 56: // Left Shift
        case 60: // Right Shift
            retval = WXK_SHIFT;
            break;
        // alt key
        case 58: // Left Alt
        case 61: // Right Alt
            retval = WXK_ALT;
            break;
        // ctrl key
        case 59: // Left Ctrl
        case 62: // Right Ctrl
            retval = WXK_RAW_CONTROL;
            break;
        // clear key
        case 71:
            retval = WXK_CLEAR;
            break;
        // tab key
        case 48:
            retval = WXK_TAB;
            break;
        default:
            break;
    }
    
    // Check for NUMPAD keys.  For KEY_UP/DOWN events we need to use the
    // WXK_NUMPAD constants, but for the CHAR event we want to use the
    // standard ascii values
    if ( eventType != wxEVT_CHAR )
    {
        switch( [event keyCode] )
        {
            case 75: // /
                retval = WXK_NUMPAD_DIVIDE;
                break;
            case 67: // *
                retval = WXK_NUMPAD_MULTIPLY;
                break;
            case 78: // -
                retval = WXK_NUMPAD_SUBTRACT;
                break;
            case 69: // +
                retval = WXK_NUMPAD_ADD;
                break;
            case 65: // .
                retval = WXK_NUMPAD_DECIMAL;
                break;
            case 82: // 0
                retval = WXK_NUMPAD0;
                break;
            case 83: // 1
                retval = WXK_NUMPAD1;
                break;
            case 84: // 2
                retval = WXK_NUMPAD2;
                break;
            case 85: // 3
                retval = WXK_NUMPAD3;
                break;
            case 86: // 4
                retval = WXK_NUMPAD4;
                break;
            case 87: // 5
                retval = WXK_NUMPAD5;
                break;
            case 88: // 6
                retval = WXK_NUMPAD6;
                break;
            case 89: // 7
                retval = WXK_NUMPAD7;
                break;
            case 91: // 8
                retval = WXK_NUMPAD8;
                break;
            case 92: // 9
                retval = WXK_NUMPAD9;
                break;
            default:
                //retval = [event keyCode];
                break;
        }
    }
    return retval;
}

void wxWidgetCocoaImpl::SetupKeyEvent(wxKeyEvent &wxevent , NSEvent * nsEvent, NSString* charString)
{
    UInt32 modifiers = [nsEvent modifierFlags] ;
    int eventType = [nsEvent type];

    wxevent.m_shiftDown = modifiers & NSShiftKeyMask;
    wxevent.m_rawControlDown = modifiers & NSControlKeyMask;
    wxevent.m_altDown = modifiers & NSAlternateKeyMask;
    wxevent.m_controlDown = modifiers & NSCommandKeyMask;

    wxevent.m_rawCode = [nsEvent keyCode];
    wxevent.m_rawFlags = modifiers;

    wxevent.SetTimestamp( (int)([nsEvent timestamp] * 1000) ) ;

    wxString chars;
    if ( eventType != NSFlagsChanged )
    {
        NSString* nschars = [[nsEvent charactersIgnoringModifiersIncludingShift] uppercaseString];
        if ( charString )
        {
            // if charString is set, it did not come from key up / key down
            wxevent.SetEventType( wxEVT_CHAR );
            chars = wxCFStringRef::AsString(charString);
        }
        else if ( nschars )
        {
            chars = wxCFStringRef::AsString(nschars);
        }
    }

    int aunichar = chars.Length() > 0 ? chars[0] : 0;
    long keyval = 0;

    if (wxevent.GetEventType() != wxEVT_CHAR)
    {
        keyval = wxOSXTranslateCocoaKey(nsEvent, wxevent.GetEventType()) ;
        switch (eventType)
        {
            case NSKeyDown :
                wxevent.SetEventType( wxEVT_KEY_DOWN )  ;
                break;
            case NSKeyUp :
                wxevent.SetEventType( wxEVT_KEY_UP )  ;
                break;
            case NSFlagsChanged :
                switch (keyval)
                {
                    case WXK_CONTROL:
                        wxevent.SetEventType( wxevent.m_controlDown ? wxEVT_KEY_DOWN : wxEVT_KEY_UP);
                        break;
                    case WXK_SHIFT:
                        wxevent.SetEventType( wxevent.m_shiftDown ? wxEVT_KEY_DOWN : wxEVT_KEY_UP);
                        break;
                    case WXK_ALT:
                        wxevent.SetEventType( wxevent.m_altDown ? wxEVT_KEY_DOWN : wxEVT_KEY_UP);
                        break;
                    case WXK_RAW_CONTROL:
                        wxevent.SetEventType( wxevent.m_rawControlDown ? wxEVT_KEY_DOWN : wxEVT_KEY_UP);
                        break;
                }
                break;
            default :
                break ;
        }
    }

    if ( !keyval )
    {
        if ( wxevent.GetEventType() == wxEVT_KEY_UP || wxevent.GetEventType() == wxEVT_KEY_DOWN )
            keyval = wxToupper( aunichar ) ;
        else
            keyval = aunichar;
    }

#if wxUSE_UNICODE
    // OS X generates events with key codes in Unicode private use area for
    // unprintable symbols such as cursor arrows (WXK_UP is mapped to U+F700)
    // and function keys (WXK_F2 is U+F705). We don't want to use them as the
    // result of wxKeyEvent::GetUnicodeKey() however as it's supposed to return
    // WXK_NONE for "non characters" so explicitly exclude them.
    //
    // We only exclude the private use area inside the Basic Multilingual Plane
    // as key codes beyond it don't seem to be currently used.
    if ( !(aunichar >= 0xe000 && aunichar < 0xf900) )
        wxevent.m_uniChar = aunichar;
#endif
    wxevent.m_keyCode = keyval;

    wxWindowMac* peer = GetWXPeer();
    if ( peer )
    {
        wxevent.SetEventObject(peer);
        wxevent.SetId(peer->GetId()) ;
    }
}

UInt32 g_lastButton = 0 ;
bool g_lastButtonWasFakeRight = false ;

// better scroll wheel support 
// see http://lists.apple.com/archives/cocoa-dev/2007/Feb/msg00050.html

@interface NSEvent (DeviceDelta)
- (CGFloat)deviceDeltaX;
- (CGFloat)deviceDeltaY;

// 10.7+
- (BOOL)hasPreciseScrollingDeltas;
- (CGFloat)scrollingDeltaX;
- (CGFloat)scrollingDeltaY;
@end

void wxWidgetCocoaImpl::SetupCoordinates(wxCoord &x, wxCoord &y, NSEvent* nsEvent)
{
    NSPoint locationInWindow = [nsEvent locationInWindow];
    
    // adjust coordinates for the window of the target view
    if ( [nsEvent window] != [m_osxView window] )
    {
        if ( [nsEvent window] != nil )
            locationInWindow = [[nsEvent window] convertBaseToScreen:locationInWindow];
        
        if ( [m_osxView window] != nil )
            locationInWindow = [[m_osxView window] convertScreenToBase:locationInWindow];
    }
    
    NSPoint locationInView = [m_osxView convertPoint:locationInWindow fromView:nil];
    wxPoint locationInViewWX = wxFromNSPoint( m_osxView, locationInView );
        
    x = locationInViewWX.x;
    y = locationInViewWX.y;

}

void wxWidgetCocoaImpl::SetupMouseEvent( wxMouseEvent &wxevent , NSEvent * nsEvent )
{
    int eventType = [nsEvent type];
    UInt32 modifiers = [nsEvent modifierFlags] ;
    
    SetupCoordinates(wxevent.m_x, wxevent.m_y, nsEvent);

    // these parameters are not given for all events
    UInt32 button = [nsEvent buttonNumber];
    UInt32 clickCount = 0;

    wxevent.m_shiftDown = modifiers & NSShiftKeyMask;
    wxevent.m_rawControlDown = modifiers & NSControlKeyMask;
    wxevent.m_altDown = modifiers & NSAlternateKeyMask;
    wxevent.m_controlDown = modifiers & NSCommandKeyMask;
    wxevent.SetTimestamp( (int)([nsEvent timestamp] * 1000) ) ;

    UInt32 mouseChord = 0;

    switch (eventType)
    {
        case NSLeftMouseDown :
        case NSLeftMouseDragged :
            mouseChord = 1U;
            break;
        case NSRightMouseDown :
        case NSRightMouseDragged :
            mouseChord = 2U;
            break;
        case NSOtherMouseDown :
        case NSOtherMouseDragged :
            mouseChord = 4U;
            break;
    }

    // Remember value of g_lastButton for later click count adjustment
    UInt32 prevLastButton = g_lastButton;

    // a control click is interpreted as a right click
    bool thisButtonIsFakeRight = false ;
    if ( button == 0 && (modifiers & NSControlKeyMask) )
    {
        button = 1 ;
        thisButtonIsFakeRight = true ;
    }

    // we must make sure that our synthetic 'right' button corresponds in
    // mouse down, moved and mouse up, and does not deliver a right down and left up
    switch (eventType)
    {
        case NSLeftMouseDown :
        case NSRightMouseDown :
        case NSOtherMouseDown :
            g_lastButton = button ;
            g_lastButtonWasFakeRight = thisButtonIsFakeRight ;
            break;
     }

    if ( button == 0 )
    {
        g_lastButton = 0 ;
        g_lastButtonWasFakeRight = false ;
    }
    else if ( g_lastButton == 1 && g_lastButtonWasFakeRight )
        button = g_lastButton ;

    // Adjust click count when clicking with different buttons,
    // otherwise we report double clicks by connecting a left click with a ctrl-left click
    switch (eventType)
    {
        case NSLeftMouseDown :
        case NSRightMouseDown :
        case NSOtherMouseDown :
        case NSLeftMouseUp :
        case NSRightMouseUp :
        case NSOtherMouseUp :
            clickCount = [nsEvent clickCount];
            if ( clickCount > 1 && button != prevLastButton )
                clickCount = 1 ;
        break;
    }

    // Adjust the chord mask to remove the primary button and add the
    // secondary button.  It is possible that the secondary button is
    // already pressed, e.g. on a mouse connected to a laptop, but this
    // possibility is ignored here:
    if( thisButtonIsFakeRight && ( mouseChord & 1U ) )
        mouseChord = ((mouseChord & ~1U) | 2U);

    if(mouseChord & 1U)
                wxevent.m_leftDown = true ;
    if(mouseChord & 2U)
                wxevent.m_rightDown = true ;
    if(mouseChord & 4U)
                wxevent.m_middleDown = true ;

    // translate into wx types
    switch (eventType)
    {
        case NSLeftMouseDown :
        case NSRightMouseDown :
        case NSOtherMouseDown :
            switch ( button )
            {
                case 0 :
                    wxevent.SetEventType( clickCount > 1 ? wxEVT_LEFT_DCLICK : wxEVT_LEFT_DOWN )  ;
                    break ;

                case 1 :
                    wxevent.SetEventType( clickCount > 1 ? wxEVT_RIGHT_DCLICK : wxEVT_RIGHT_DOWN ) ;
                    break ;

                case 2 :
                    wxevent.SetEventType( clickCount > 1 ? wxEVT_MIDDLE_DCLICK : wxEVT_MIDDLE_DOWN ) ;
                    break ;

                default:
                    break ;
            }
            break ;

        case NSLeftMouseUp :
        case NSRightMouseUp :
        case NSOtherMouseUp :
            switch ( button )
            {
                case 0 :
                    wxevent.SetEventType( wxEVT_LEFT_UP )  ;
                    break ;

                case 1 :
                    wxevent.SetEventType( wxEVT_RIGHT_UP ) ;
                    break ;

                case 2 :
                    wxevent.SetEventType( wxEVT_MIDDLE_UP ) ;
                    break ;

                default:
                    break ;
            }
            break ;

     case NSScrollWheel :
        {
            float deltaX = 0.0;
            float deltaY = 0.0;

            wxevent.SetEventType( wxEVT_MOUSEWHEEL ) ;

            if ( UMAGetSystemVersion() >= 0x1070 )
            {
                if ( [nsEvent hasPreciseScrollingDeltas] )
                {
                    deltaX = [nsEvent scrollingDeltaX];
                    deltaY = [nsEvent scrollingDeltaY];
                }
                else
                {
                    deltaX = [nsEvent scrollingDeltaX] * 10;
                    deltaY = [nsEvent scrollingDeltaY] * 10;
                }
            }
            else
            {
                const EventRef cEvent = (EventRef) [nsEvent eventRef];
                // see http://developer.apple.com/qa/qa2005/qa1453.html
                // for more details on why we have to look for the exact type
                
                bool isMouseScrollEvent = false;
                if ( cEvent )
                    isMouseScrollEvent = ::GetEventKind(cEvent) == kEventMouseScroll;
                
                if ( isMouseScrollEvent )
                {
                    deltaX = [nsEvent deviceDeltaX];
                    deltaY = [nsEvent deviceDeltaY];
                }
                else
                {
                    deltaX = ([nsEvent deltaX] * 10);
                    deltaY = ([nsEvent deltaY] * 10);
                }
            }
            
            wxevent.m_wheelDelta = 10;
            wxevent.m_linesPerAction = 1;
            wxevent.m_columnsPerAction = 1;
                
            if ( fabs(deltaX) > fabs(deltaY) )
            {
                // wx conventions for horizontal are inverted from vertical (originating from native msw behavior)
                // right and up are positive values, left and down are negative values, while on OSX right and down
                // are negative and left and up are positive.
                wxevent.m_wheelAxis = wxMOUSE_WHEEL_HORIZONTAL;
                wxevent.m_wheelRotation = -(int)deltaX;
            }
            else
            {
                wxevent.m_wheelRotation = (int)deltaY;
            }

        }
        break ;

        case NSMouseEntered :
            wxevent.SetEventType( wxEVT_ENTER_WINDOW ) ;
            break;
        case NSMouseExited :
            wxevent.SetEventType( wxEVT_LEAVE_WINDOW ) ;
            break;
        case NSLeftMouseDragged :
        case NSRightMouseDragged :
        case NSOtherMouseDragged :
        case NSMouseMoved :
            wxevent.SetEventType( wxEVT_MOTION ) ;
            break;
        
        case NSEventTypeMagnify:
            wxevent.SetEventType( wxEVT_MAGNIFY );
            wxevent.m_magnification = [nsEvent magnification];
            break;
            
        default :
            break ;
    }

    wxevent.m_clickCount = clickCount;
    wxWindowMac* peer = GetWXPeer();
    if ( peer )
    {
        wxevent.SetEventObject(peer);
        wxevent.SetId(peer->GetId()) ;
    }
}

@implementation wxNSView

+ (void)initialize
{
    static BOOL initialized = NO;
    if (!initialized)
    {
        initialized = YES;
        wxOSXCocoaClassAddWXMethods( self );
    }
}

/* idea taken from webkit sources: overwrite the methods that (private) NSToolTipManager will use to attach its tracking rectangle 
 * then when changing the tooltip send fake view-exit and view-enter methods which will lead to a tooltip refresh
 */


- (void)_sendToolTipMouseExited
{
    // Nothing matters except window, trackingNumber, and userData.
    NSEvent *fakeEvent = [NSEvent enterExitEventWithType:NSMouseExited
                                                location:NSMakePoint(0, 0)
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:[[self window] windowNumber]
                                                 context:NULL
                                             eventNumber:0
                                          trackingNumber:_lastToolTipTrackTag
                                                userData:_lastUserData];
    [_lastToolTipOwner mouseExited:fakeEvent];
}

- (void)_sendToolTipMouseEntered
{
    // Nothing matters except window, trackingNumber, and userData.
    NSEvent *fakeEvent = [NSEvent enterExitEventWithType:NSMouseEntered
                                                location:NSMakePoint(0, 0)
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:[[self window] windowNumber]
                                                 context:NULL
                                             eventNumber:0
                                          trackingNumber:_lastToolTipTrackTag
                                                userData:_lastUserData];
    [_lastToolTipOwner mouseEntered:fakeEvent];
}

- (void)setToolTip:(NSString *)string
{
    if (string)
    {
        if ( _hasToolTip )
        {
            [self _sendToolTipMouseExited];
        }

        [super setToolTip:string];
        _hasToolTip = YES;
        [self _sendToolTipMouseEntered];
    }
    else 
    {
        if ( _hasToolTip )
        {
            [self _sendToolTipMouseExited];
            [super setToolTip:nil];
            _hasToolTip = NO;
        }
    }
}

- (NSTrackingRectTag)addTrackingRect:(NSRect)rect owner:(id)owner userData:(void *)data assumeInside:(BOOL)assumeInside
{
    NSTrackingRectTag tag = [super addTrackingRect:rect owner:owner userData:data assumeInside:assumeInside];
    if ( owner != self )
    {
        _lastUserData = data;
        _lastToolTipOwner = owner;
        _lastToolTipTrackTag = tag;
    }
    return tag;
}

- (void)removeTrackingRect:(NSTrackingRectTag)tag
{
    if (tag == _lastToolTipTrackTag) 
    {
        _lastUserData = NULL;
        _lastToolTipOwner = nil;
        _lastToolTipTrackTag = 0;
    }
    [super removeTrackingRect:tag];
}

#if wxOSX_USE_NATIVE_FLIPPED
- (BOOL)isFlipped
{
    return YES;
}
#endif

- (BOOL) canBecomeKeyView
{
    wxWidgetCocoaImpl* viewimpl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if ( viewimpl && viewimpl->IsUserPane() && viewimpl->GetWXPeer() )
        return viewimpl->GetWXPeer()->AcceptsFocus();
    return NO;
}

@end // wxNSView

// We need to adopt NSTextInputClient protocol in order to interpretKeyEvents: to work.
// Currently, only insertText:(replacementRange:) is
// implemented here, and the rest of the methods are stubs.
// It is hoped that someday IME-related functionality is implemented in
// wxWidgets and the methods of this protocol are fully working.

@implementation wxNSView(TextInput)

void wxOSX_insertText(NSView* self, SEL _cmd, NSString* text);

- (void)insertText:(id)aString replacementRange:(NSRange)replacementRange
{
    wxOSX_insertText(self, @selector(insertText:), aString);
}

- (void)doCommandBySelector:(SEL)aSelector
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl)
        impl->doCommandBySelector(aSelector, self, _cmd);
}

- (void)setMarkedText:(id)aString selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange
{
}

- (void)unmarkText
{
}

- (NSRange)selectedRange
{    
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)markedRange
{
    return NSMakeRange(NSNotFound, 0);
}

- (BOOL)hasMarkedText
{
    return NO;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)aRange actualRange:(NSRangePointer)actualRange
{
    return nil;
}

- (NSArray*)validAttributesForMarkedText
{
    return nil;
}

- (NSRect)firstRectForCharacterRange:(NSRange)aRange actualRange:(NSRangePointer)actualRange
{
    return NSMakeRect(0, 0, 0, 0);
}
- (NSUInteger)characterIndexForPoint:(NSPoint)aPoint
{
    return NSNotFound;
}

@end // wxNSView(TextInput)


// An objective-C object that can be returned to Cocoa to receive the
// callbacks for accessibility, in case its parent defines it as an accessible
// sub-element that does not correspond to an entire wxWindow.
@interface wxAccessibilityChild : NSObject
{
   wxAccessible *accessible;
   NSInteger number;
}

- (id)initWithAccessible: (wxAccessible*)accessible_
               andNumber: (NSInteger)number_;

+ (id)accessibilityChildWithAccessible: (wxAccessible*)accessible_
                             andNumber: (NSInteger)number_;
@end

//
// event handlers
//

#if wxUSE_DRAG_AND_DROP

// see http://lists.apple.com/archives/Cocoa-dev/2005/Jul/msg01244.html
// for details on the NSPasteboard -> PasteboardRef conversion

NSDragOperation wxOSX_draggingEntered( id self, SEL _cmd, id <NSDraggingInfo>sender )
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NSDragOperationNone;

    return impl->draggingEntered(sender, self, _cmd);
}

void wxOSX_draggingExited( id self, SEL _cmd, id <NSDraggingInfo> sender )
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return ;

    return impl->draggingExited(sender, self, _cmd);
}

NSDragOperation wxOSX_draggingUpdated( id self, SEL _cmd, id <NSDraggingInfo>sender )
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NSDragOperationNone;

    return impl->draggingUpdated(sender, self, _cmd);
}

BOOL wxOSX_performDragOperation( id self, SEL _cmd, id <NSDraggingInfo> sender )
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NSDragOperationNone;

    return impl->performDragOperation(sender, self, _cmd) ? YES:NO ;
}

namespace {

   wxAccessible *findAccessible( id view )
   {
      wxWidgetCocoaImpl* impl;
      wxWindow* win;
      wxAccessible *accessible;

      if ((impl =
           (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( view )) &&
          (win = impl->GetWXPeer()) &&
          (accessible = win->GetAccessible()))
         return accessible;

      return NULL;
   }

   id GetUIElement
   (wxAccessible &accessible, int childID = wxACC_SELF,
    wxAccessible *pChild = NULL)
   {
      if (pChild)
         return pChild->GetWindow()->GetPeer()->GetWXWidget();
      else
         return
         [wxAccessibilityChild accessibilityChildWithAccessible: &accessible
                                                      andNumber: childID];
   }

   struct wxNSAccessibilityAttribute
   {
      explicit
      wxNSAccessibilityAttribute(NSString *name_, bool dummy = false);

      struct Hash
      {
         size_t operator()( const void* k ) const
         {
            return
               [static_cast<const wxNSAccessibilityAttribute*>(k)->name hash];
         }
      };

      struct Equal
      {
         bool operator()( const void* a, const void* b ) const
         {
            return
               [static_cast<const wxNSAccessibilityAttribute*>(a)->name
                isEqual:
                static_cast<const wxNSAccessibilityAttribute*>(b)->name];
         }
      };

      void RaiseException(id element, id value = nil) const
      {
         NSAccessibilityRaiseBadArgumentException(element, name, value);
      }

      virtual bool IsPresent
         (id element, wxAccessible &accessible, int childID) const
      {
         return false;
      }

      virtual bool IsSettable
         (id element, wxAccessible &accessible, int childID) const
      {
         return false;
      }

      virtual id Get
         (id element, wxAccessible &accessible, int childID) const
      {
         RaiseException(element);
         return nil;
      }

      virtual void Set
         (id element, wxAccessible &accessible, int childID, id value) const
      {
         RaiseException(element, value);
      }

      NSString *const name;
   };

   WX_DECLARE_HASH_SET(
      wxNSAccessibilityAttribute*,
      wxNSAccessibilityAttribute::Hash,
      wxNSAccessibilityAttribute::Equal,
      AllAttributes
   );

   AllAttributes sAllAttributes;

   wxNSAccessibilityAttribute::wxNSAccessibilityAttribute
      (NSString *name_, bool dummy)
   : name (name_)
   {
      if (!dummy)
         sAllAttributes.insert(this);
   }

   const wxNSAccessibilityAttribute *findAttribute(id element, NSString *name)
   {
      wxNSAccessibilityAttribute attr(name, true);
      AllAttributes::const_iterator it = sAllAttributes.find(&attr);
      if (it != sAllAttributes.end())
         return *it;
      return NULL;
   }

   NSArray *findAttributeNames
   ( id self, wxAccessible &accessible, int childId,
    NSArray *otherAttributes )
   {
      NSMutableArray *result =
      otherAttributes
      ? [NSMutableArray arrayWithArray: otherAttributes]
      : [NSMutableArray arrayWithCapacity: sAllAttributes.size()];
      AllAttributes::const_iterator it = sAllAttributes.begin(),
      end = sAllAttributes.end();
      for (; it != end; ++it)
      {
         const wxNSAccessibilityAttribute &attribute = **it;
         if (attribute.IsPresent(self, accessible, childId)) {
            NSString *name = attribute.name;
            if (otherAttributes && [otherAttributes containsObject: name])
               // don't duplicate
               continue;
            [result addObject: name];
         }
      }
      return result;
   }

   // Useful, still abstract, subclass of wxNSAccessibilityAttribute
   // helps to implement other parts of the protocol that query only the
   // size or a sub-range of the arrays.
   struct wxNSAccessibilityArrayAttribute : wxNSAccessibilityAttribute
   {
      explicit
      wxNSAccessibilityArrayAttribute(NSString *name)
      : wxNSAccessibilityAttribute(name)
      {}

      virtual unsigned GetCount
      (id element, wxAccessible &accessible, int childID) const = 0;

      virtual id GetArrayElement
      (id element, wxAccessible &accessible, int childID,
       unsigned index) const = 0;

      NSUInteger IndexOfValue
      (id element, wxAccessible &accessible, int childID, id value) const
      {
         unsigned count = GetCount(element, accessible, childID);
         for (unsigned index = 0; index < count; ++index)
         {
            id arrayElement =
            GetArrayElement(element, accessible, childID, index);
            if ([value isEqual: arrayElement])
               return index;
         }
         return NSNotFound;
      }

      id GetValues
      (id element, wxAccessible &accessible, int childID,
       unsigned index, unsigned maxCount) const
      {
         if (maxCount == 0)
            return [NSArray array];

         NSMutableArray *result =
         [NSMutableArray arrayWithCapacity: (NSUInteger)maxCount];

         unsigned limit = index + maxCount;
         while (index < limit)
         {
            id arrayElement =
            GetArrayElement(element, accessible, childID, index);
            if (arrayElement)
               [result addObject: arrayElement];
            ++index;
         }
         return result;
      }

      virtual id Get
      (id element, wxAccessible &accessible, int childID) const
      {
         unsigned count = GetCount(element, accessible, childID);
         return GetValues(element, accessible, childID, 0, count);
      }
   };

   struct wxNAccessibilityStringAttribute : wxNSAccessibilityAttribute
   {
      typedef wxAccStatus (wxAccessible::*PMF)(int, wxString*);

      wxNAccessibilityStringAttribute(NSString *name_, PMF pmf_)
      : wxNSAccessibilityAttribute(name_)
      , pmf(pmf_)
      {}

      virtual bool IsPresent
      (id element, wxAccessible &accessible, int childID) const
      {
         wxString str;
         return (wxACC_OK == (accessible.*pmf)(childID, &str));
      }

      virtual id Get
      (id element, wxAccessible &accessible, int childID) const
      {
         wxString result;
         if (wxACC_OK == (accessible.*pmf)(childID, &result))
            return wxNSStringWithWxString(result);
         else
            return @"";
      }

      const PMF pmf;
   };

   template <
      unsigned long StateFlag, bool StateFlagState,
      unsigned long SettableFlag, bool SettableFlagState,
      wxAccSelectionFlags SelectFlag
   > struct wxNSAccessibilityStateAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilityStateAttribute(NSString *name)
      : wxNSAccessibilityAttribute(name)
      {}

      virtual bool IsPresent
      (id element, wxAccessible &accessible, int childID) const
      {
         return true;
      }

      virtual id Get
      (id, wxAccessible &accessible, int childID) const
      {
         BOOL result = NO;
         long state = 0;
         wxAccStatus status = accessible.GetState(childID, &state);
         if (wxACC_OK == status &&
             StateFlagState == !!(state & StateFlag))
            result = YES;
         return [NSNumber numberWithBool: result];
      }

      virtual bool IsSettable
      (id element, wxAccessible &accessible, int childID) const
      {
         long state = 0;
         wxAccStatus status = accessible.GetState(childID, &state);
         return
         (wxACC_OK == status &&
          SettableFlagState == !!(state & SettableFlag));
      }

      virtual void Set
      (id element, wxAccessible &accessible, int childID, id value) const
      {
         wxAccStatus status = accessible.Select(childID, SelectFlag);
         WXUNUSED(status);
      }
   };
   
   // To do: for each of these attributes that is important, make a static
   // object of a subclass of wxNSAccessibilityAttribute that gets and sets it.

   /* Standard attributes
    */

   struct wxNSAccessibilityRoleAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilityRoleAttribute ()
      : wxNSAccessibilityAttribute(NSAccessibilityRoleAttribute) {}

      virtual bool
      IsPresent(id element, wxAccessible &accessible, int childID) const
      {
         return true;
      }

      virtual id
      Get(id element, wxAccessible &accessible, int childID) const
      {
         // Standard NSAccessibility roles that did not obviously correspond
         // to any of the wxROLE constants
         /*
          NSAccessibilityTextAreaRole;
          NSAccessibilityScrollAreaRole;
          NSAccessibilityRadioGroupRole;
          NSAccessibilityBusyIndicatorRole;
          NSAccessibilityDrawerRole;
          NSAccessibilitySystemWideRole;
          NSAccessibilityBrowserRole;
          NSAccessibilitySplitGroupRole;
          NSAccessibilityColorWellRole;
          NSAccessibilityMatteRole;
          NSAccessibilityRulerRole;
          NSAccessibilityRulerMarkerRole;
          NSAccessibilityRelevanceIndicatorRole;
          NSAccessibilityLevelIndicatorRole;

          NSAccessibilityLayoutItemRole;

          NSAccessibilityGridRole;
          */

         wxAccRole role;
         if (wxACC_OK == accessible.GetRole(childID, &role)) switch (role)
         {
            case wxROLE_SYSTEM_ANIMATION:
               return NSAccessibilityImageRole; // ??

            case wxROLE_SYSTEM_APPLICATION:
               return NSAccessibilityApplicationRole;

            case wxROLE_SYSTEM_BORDER:
               return NSAccessibilityGrowAreaRole; // ??

            case wxROLE_SYSTEM_BUTTONDROPDOWN:
            case wxROLE_SYSTEM_BUTTONDROPDOWNGRID:
               return NSAccessibilityPopUpButtonRole;

            case wxROLE_SYSTEM_BUTTONMENU:
               return NSAccessibilityMenuButtonRole;

            case wxROLE_SYSTEM_CELL:
               return NSAccessibilityCellRole;

            case wxROLE_SYSTEM_CHART:
               return NSAccessibilityImageRole; // ??

            case wxROLE_SYSTEM_CHECKBUTTON:
               return NSAccessibilityCheckBoxRole;

            case wxROLE_SYSTEM_COLUMN:
            case wxROLE_SYSTEM_COLUMNHEADER:
               return NSAccessibilityColumnRole;

            case wxROLE_SYSTEM_COMBOBOX:
               return NSAccessibilityComboBoxRole;

            case wxROLE_SYSTEM_DIAGRAM:
               return NSAccessibilityImageRole; // ??

            case wxROLE_SYSTEM_DIAL:
               return NSAccessibilitySliderRole; //??

            case wxROLE_SYSTEM_DIALOG:
               return NSAccessibilitySheetRole;

            case wxROLE_SYSTEM_DOCUMENT:
               return NSAccessibilityTextAreaRole; // ??

            case wxROLE_SYSTEM_DROPLIST:
               return NSAccessibilityMenuRole; // ??

            case wxROLE_SYSTEM_GRAPHIC:
               return NSAccessibilityImageRole;

            case wxROLE_SYSTEM_GRIP:
               return NSAccessibilityHandleRole;

            case wxROLE_SYSTEM_GROUPING:
               return NSAccessibilityGroupRole;

            case wxROLE_SYSTEM_HELPBALLOON:
               return NSAccessibilityHelpTagRole;

            case wxROLE_SYSTEM_HOTKEYFIELD:
               return NSAccessibilityTextFieldRole; // ??

            case wxROLE_SYSTEM_INDICATOR:
               return NSAccessibilityValueIndicatorRole;

            case wxROLE_SYSTEM_LINK:
               return NSAccessibilityLinkRole;

            case wxROLE_SYSTEM_LIST:
               return NSAccessibilityListRole;

            case wxROLE_SYSTEM_LISTITEM:
               return NSAccessibilityMenuItemRole; // ??

            case wxROLE_SYSTEM_MENUBAR:
               return NSAccessibilityMenuBarRole;

            case wxROLE_SYSTEM_MENUITEM:
               return NSAccessibilityMenuItemRole;

            case wxROLE_SYSTEM_MENUPOPUP:
               return NSAccessibilityMenuRole;

            case wxROLE_SYSTEM_OUTLINE:
               return NSAccessibilityOutlineRole;

            case wxROLE_SYSTEM_OUTLINEITEM:
               return NSAccessibilityDisclosureTriangleRole; // ??

            case wxROLE_SYSTEM_PAGETAB:
               return NSAccessibilityButtonRole; // ???

            case wxROLE_SYSTEM_PAGETABLIST:
               return NSAccessibilityTabGroupRole; // ??

            case wxROLE_SYSTEM_PANE:
               return NSAccessibilityLayoutAreaRole; // ??

            case wxROLE_SYSTEM_PROGRESSBAR:
               return NSAccessibilityProgressIndicatorRole;

            case wxROLE_SYSTEM_PROPERTYPAGE:
               return NSAccessibilitySheetRole; // ??

            case wxROLE_SYSTEM_PUSHBUTTON:
               return NSAccessibilityButtonRole;

            case wxROLE_SYSTEM_RADIOBUTTON:
               return NSAccessibilityRadioButtonRole;

            case wxROLE_SYSTEM_ROWHEADER:
            case wxROLE_SYSTEM_ROW:
               return NSAccessibilityRowRole;

            case wxROLE_SYSTEM_SCROLLBAR:
               return NSAccessibilityScrollBarRole;

            case wxROLE_SYSTEM_SEPARATOR:
               return NSAccessibilitySplitterRole; // ??

            case wxROLE_SYSTEM_SLIDER:
               return NSAccessibilitySliderRole;

            case wxROLE_SYSTEM_SPINBUTTON:
               return NSAccessibilityIncrementorRole;

            case wxROLE_SYSTEM_STATICTEXT:
               return NSAccessibilityStaticTextRole;

            case wxROLE_SYSTEM_STATUSBAR:
               return NSAccessibilityStaticTextRole; // ??

            case wxROLE_SYSTEM_TABLE:
               return NSAccessibilityTableRole;

            case wxROLE_SYSTEM_TEXT:
               return NSAccessibilityTextFieldRole;

            case wxROLE_SYSTEM_TITLEBAR:
               return NSAccessibilityStaticTextRole; // ??

            case wxROLE_SYSTEM_TOOLBAR:
               return NSAccessibilityToolbarRole;

            case wxROLE_SYSTEM_TOOLTIP:
               return NSAccessibilityHelpTagRole; // ??

            case wxROLE_SYSTEM_WHITESPACE:
               return NSAccessibilityStaticTextRole; // ??

            case wxROLE_SYSTEM_WINDOW:
               return NSAccessibilityWindowRole;

               // wxROLE constants that did not correspond to anything obvious
               // in the list of standard NSAccessibility roles
            case wxROLE_NONE:
            case wxROLE_SYSTEM_ALERT:
            case wxROLE_SYSTEM_CARET:
            case wxROLE_SYSTEM_CHARACTER:
            case wxROLE_SYSTEM_CLIENT:
            case wxROLE_SYSTEM_CLOCK:
            case wxROLE_SYSTEM_CURSOR:
            case wxROLE_SYSTEM_EQUATION:
            case wxROLE_SYSTEM_SOUND:
            default:
               return NSAccessibilityUnknownRole;
         }
         else
            return NSAccessibilityUnknownRole;
      }
   } swxNSAccessibilityRoleAttribute;

   struct wxNSAccessibilitySubroleAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilitySubroleAttribute ()
      : wxNSAccessibilityAttribute(NSAccessibilitySubroleAttribute) {}

      virtual bool
      IsPresent(id element, wxAccessible &accessible, int childID) const
      {
         return true;
      }

      virtual id
      Get(id element, wxAccessible &accessible, int childID) const
      {
         // Improve this
         return NSAccessibilityUnknownSubrole;
      }
   } swxNSAccessibilitySubroleAttribute;
   
   struct wxNSAccessibilityRoleDescriptionAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilityRoleDescriptionAttribute ()
      : wxNSAccessibilityAttribute(NSAccessibilityRoleDescriptionAttribute) {}
      
      virtual bool
      IsPresent(id element, wxAccessible &accessible, int childID) const
      {
         return true;
      }
      
      virtual id
      Get(id element, wxAccessible &accessible, int childID) const
      {
         id role =
         swxNSAccessibilityRoleAttribute.Get(element, accessible, childID);
         id subRole =
         swxNSAccessibilitySubroleAttribute.Get(element, accessible, childID);
         NSString *result =
         NSAccessibilityRoleDescription((NSString*)role, (NSString*)subRole);
         return result;
      }
   } swxNSAccessibilityRoleDescriptionAttribute;

   wxNAccessibilityStringAttribute sxwNSAccessibilityHelpAttribute
      (NSAccessibilityHelpAttribute, &wxAccessible::GetHelpText);

   // Not different from value -- is that right?
   wxNAccessibilityStringAttribute sxwNSAccessibilityValueAttribute
      (NSAccessibilityValueAttribute, &wxAccessible::GetValue);

#if 0
   NSAccessibilityMinValueAttribute;		//(id)         - element's min value
   NSAccessibilityMaxValueAttribute;		//(id)         - element's max value
#endif

   wxNSAccessibilityStateAttribute <
      wxACC_STATE_SYSTEM_UNAVAILABLE, false,
      0, true, wxACC_SEL_NONE // not settable
   > swxNSAccessibilityEnabledAttribute(NSAccessibilityEnabledAttribute);

   wxNSAccessibilityStateAttribute <
      wxACC_STATE_SYSTEM_FOCUSED, true,
      wxACC_STATE_SYSTEM_FOCUSABLE, true,
      wxACC_SEL_TAKEFOCUS
   > swxNSAccessibilityFocusedAttribute(NSAccessibilityFocusedAttribute);

   struct wxNSAccessibilityParentAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilityParentAttribute()
      : wxNSAccessibilityAttribute(NSAccessibilityParentAttribute)
      {}

      virtual bool IsPresent
      (id element, wxAccessible &accessible, int childID) const
      {
         return nil != Get(element, accessible, childID);
      }

      virtual id Get
      (id, wxAccessible &accessible, int childID) const
      {
         // I'm not using wxAccessible::GetParent() because the default
         // implementation has the undesirable side effect of creating
         // wxAccessible objects for windows that did not already have them.

         wxWindow *window = accessible.GetWindow();

         if (childID != wxACC_SELF)
            // report parent of non-window accessible element
            return window->GetPeer()->GetWXWidget();

         // Report direct parent window if that defines a wxAccessible
         wxWindow *parent = window->GetParent();
         if (parent && parent->GetAccessible())
         {
            NSObject *widget = parent->GetPeer()->GetWXWidget();
            return widget;
         }

         // Cause defaulting to the framework's definition of parent
         return nil;
      }
   } swxNSAccessibilityParentAttribute;

   //(NSArray *)  - elements you contain
   struct wxNSAccessibilityChildrenAttributeBase : wxNSAccessibilityArrayAttribute
   {
      wxNSAccessibilityChildrenAttributeBase(NSString *name_)
      : wxNSAccessibilityArrayAttribute(name_)
      {}

      virtual bool Condition
         (wxAccessible &accessible, int childID,
          wxAccessible *pChild) const = 0;

      virtual bool IsPresent
         (id element, wxAccessible &accessible, int childID) const
      {
         return true;
      }

      virtual unsigned GetCount
      (id element, wxAccessible &accessible, int childID) const
      {
         if (childID != 0)
            return 0;

         int childCount;
         wxAccStatus status = accessible.GetChildCount(&childCount);
         if (status != wxACC_OK || childCount <= 0)
            return 0;
         else
            return childCount;
      }

      virtual id GetArrayElement
      (id element, wxAccessible &accessible, int childID,
       unsigned index) const
      {
         if (childID != 0)
            return nil;

         wxAccessible *child = NULL;
         wxAccStatus status = accessible.GetChild(index + 1, &child);
         if (status != wxACC_OK)
            return nil;

         if (!Condition(accessible, index + 1, child))
            return nil;

         return GetUIElement(accessible, index + 1, child);
      }
   };

   struct wxNSAccessibilityChildrenAttribute
   : wxNSAccessibilityChildrenAttributeBase
   {
      explicit
      wxNSAccessibilityChildrenAttribute
         (NSString *attr = NSAccessibilityChildrenAttribute)
      : wxNSAccessibilityChildrenAttributeBase(attr)
      {}

      virtual bool Condition(wxAccessible &, int, wxAccessible *) const
      {
         return true;
      }

   } swxNSAccessibilityChildrenAttribute;

   struct wxNSAccessibilityWindowAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilityWindowAttribute ()
      : wxNSAccessibilityAttribute(NSAccessibilityWindowAttribute) {}

      virtual bool IsPresent
      (id element, wxAccessible &accessible, int childID) const
      {
         return true;
      }

      virtual id Get
      (id element, wxAccessible &accessible, int childID) const
      {
         wxWindow *pWindow = accessible.GetWindow(), *pParent;
         while (!dynamic_cast<wxNonOwnedWindow*>(pWindow) &&
            NULL != (pParent = pWindow->GetParent()))
            pWindow = pParent;
         NSObject *widget = pWindow->GetPeer()->GetWXWidget();
         return widget;
      }
   } swxNSAccessibilityWindowAttribute;

   struct wxNSAccessibilityTopLevelUIAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilityTopLevelUIAttribute ()
      : wxNSAccessibilityAttribute(NSAccessibilityTopLevelUIElementAttribute) {}

      virtual bool IsPresent
      (id element, wxAccessible &accessible, int childID) const
      {
         return false;
      }

      virtual id Get
      (id element, wxAccessible &accessible, int childID) const
      {
         return element;
         /*
         id prevElement = element, newElement;
         do try {
            newElement =
               [element accessibilityAttributeValue: NSAccessibilityParentAttribute];
         }
         catch(...) {
            return prevElement;
         }
         while (newElement != NULL &&
                (prevElement = element, element = newElement));
         return element;
          */
      }
   } swxNSAccessibilityTopLevelUIAttribute;
   
   struct wxNSAccessibilitySelectedChildrenAttribute
   : wxNSAccessibilityChildrenAttributeBase
   {
      explicit
      wxNSAccessibilitySelectedChildrenAttribute
         (NSString *attr = NSAccessibilitySelectedChildrenAttribute)
      : wxNSAccessibilityChildrenAttributeBase(attr)
      {}

      virtual bool Condition
      (wxAccessible &accessible, int childID,
       wxAccessible *pChild) const
      {
         wxAccStatus status;
         long state = 0;
         if (pChild)
            status = pChild->GetState(wxACC_SELF, &state);
         else
            status = accessible.GetState(childID, &state);

         return (status == wxACC_OK &&
                 0 != (state & wxACC_STATE_SYSTEM_SELECTED));
      }
   } swxNSAccessibilitySelectedChildrenAttribute;

   struct wxNSAccessibilityVisibleChildrenAttribute
   : wxNSAccessibilityChildrenAttributeBase
   {
      explicit
      wxNSAccessibilityVisibleChildrenAttribute
         (NSString *attr = NSAccessibilityVisibleChildrenAttribute)
      : wxNSAccessibilityChildrenAttributeBase(attr)
      {}

      virtual bool Condition
      (wxAccessible &accessible, int childID,
       wxAccessible *pChild) const
      {
         wxAccStatus status;
         long state = 0;
         if (pChild)
            status = pChild->GetState(wxACC_SELF, &state);
         else
            status = accessible.GetState(childID, &state);

         return (status == wxACC_OK &&
                 0 == (state & wxACC_STATE_SYSTEM_INVISIBLE));
      }
   } swxNSAccessibilityVisibleChildrenAttribute;

   struct wxNSAccessibilityPositionAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilityPositionAttribute ()
      : wxNSAccessibilityAttribute(NSAccessibilityPositionAttribute) {}

      virtual bool IsPresent
      (id element, wxAccessible &accessible, int childID) const
      {
         wxRect rect;
         return (wxACC_OK == accessible.GetLocation(rect, childID));
      }

      virtual id
      Get(id element, wxAccessible &accessible, int childID) const
      {
         wxRect rect;
         NSPoint point = { 0, 0 };
         if (wxACC_OK == accessible.GetLocation(rect, childID))
         {
            int height;
            ::wxDisplaySize(NULL, &height);
            point.x = rect.x, point.y = height - rect.y - rect.height;
         }
         return [NSValue valueWithBytes: &point objCType: @encode(NSPoint)];
      }
   } swxNSAccessibilityPositionAttribute;

   struct wxNSAccessibilitySizeAttribute : wxNSAccessibilityAttribute
   {
      wxNSAccessibilitySizeAttribute ()
      : wxNSAccessibilityAttribute(NSAccessibilitySizeAttribute) {}

      virtual bool
      IsPresent(id element, wxAccessible &accessible, int childID) const
      {
         wxRect rect;
         return (wxACC_OK == accessible.GetLocation(rect, childID));
      }

      virtual id
      Get(id element, wxAccessible &accessible, int childID) const
      {
         wxRect rect;
         NSSize size = { 0, 0 };
         if (wxACC_OK == accessible.GetLocation(rect, childID))
            size.width = rect.width, size.height = rect.height;
         return [NSValue valueWithBytes: &size objCType: @encode(NSSize)];
      }
   } swxNSAccessibilitySizeAttribute;

   // Make "contents" no different from "children" -- is that right?
   wxNSAccessibilityChildrenAttribute
      swxNSAccessibilityContentsAttribute(NSAccessibilityContentsAttribute);

   wxNAccessibilityStringAttribute sxwNSAccessibilityTitleAttribute
      (NSAccessibilityTitleAttribute, &wxAccessible::GetName);
   wxNAccessibilityStringAttribute sxwNSAccessibilityDescriptionAttribute
      (NSAccessibilityDescriptionAttribute, &wxAccessible::GetDescription);

#if 0
   NSAccessibilityShownMenuAttribute		//(id)         - menu being displayed
   ;
#endif

   wxNAccessibilityStringAttribute sxwNSAccessibilityValueDescriptionAttribute
      (NSAccessibilityValueDescriptionAttribute, &wxAccessible::GetValue);

#if 0
   /* Misc attributes
    */
   NSAccessibilityPreviousContentsAttribute;	//(NSArray *)  - main elements
   NSAccessibilityNextContentsAttribute;	//(NSArray *)  - main elements
   NSAccessibilityHeaderAttribute;		//(id)         - UIElement for header.
   NSAccessibilityEditedAttribute;		//(NSNumber *) - (boolValue) is it dirty?
   NSAccessibilityTabsAttribute;		//(NSArray *)  - UIElements for tabs
   NSAccessibilityHorizontalScrollBarAttribute;//(id)       - UIElement for the horizontal scroller
   NSAccessibilityVerticalScrollBarAttribute;//(id)         - UIElement for the vertical scroller
   NSAccessibilityOverflowButtonAttribute;	//(id)         - UIElement for overflow
   NSAccessibilityIncrementButtonAttribute;	//(id)         - UIElement for increment
   NSAccessibilityDecrementButtonAttribute;	//(id)         - UIElement for decrement
   NSAccessibilityFilenameAttribute;		//(NSString *) - filename
#endif

   wxNSAccessibilityStateAttribute <
      wxACC_STATE_SYSTEM_EXPANDED, true,
      0, true, wxACC_SEL_NONE // not settable
   > swxNSAccessibilityExpandedAttribute(NSAccessibilityExpandedAttribute);

   wxNSAccessibilityStateAttribute <
      wxACC_STATE_SYSTEM_SELECTED, true,
      wxACC_STATE_SYSTEM_SELECTABLE, true,
      wxACC_SEL_TAKESELECTION
   > swxNSAccessibilitySelectedAttribute(NSAccessibilitySelectedAttribute);

#if 0
   NSAccessibilitySplittersAttribute;	//(NSArray *)  - UIElements for splitters
   NSAccessibilityDocumentAttribute;		//(NSString *) - url as string - for open document
   NSAccessibilityURLAttribute		//(NSURL *)    - url
   ;
   NSAccessibilityIndexAttribute		//(NSNumber *)  - (intValue)
   ;

   NSAccessibilityRowCountAttribute		//(NSNumber *)  - (intValue) number of rows
   ;
   NSAccessibilityColumnCountAttribute	//(NSNumber *)  - (intValue) number of columns
   ;
   NSAccessibilityOrderedByRowAttribute	//(NSNumber *)  - (boolValue) is ordered by row?
   ;

   NSAccessibilityWarningValueAttribute	//(id)  - warning value of a level indicator, typically a number
   ;
   NSAccessibilityCriticalValueAttribute	//(id)  - critical value of a level indicator, typically a number
   ;
   NSAccessibilityPlaceholderValueAttribute	//(NSString *)  - placeholder value of a control such as a text field
   ;

   /* Linkage attributes
    */
   NSAccessibilityTitleUIElementAttribute;		//(id)	      - UIElement for the title
   NSAccessibilityServesAsTitleForUIElementsAttribute//(NSArray *) - UIElements this titles
   ;
   NSAccessibilityLinkedUIElementsAttribute		//(NSArray *) - corresponding UIElements
   ;


   /* Text-specific attributes
    */
   NSAccessibilitySelectedTextAttribute;		//(NSString *) - selected text
   NSAccessibilitySelectedTextRangeAttribute;	//(NSValue *)  - (rangeValue) range of selected text
   NSAccessibilityNumberOfCharactersAttribute	//(NSNumber *) - number of characters
   ;
   NSAccessibilityVisibleCharacterRangeAttribute	//(NSValue *)  - (rangeValue) range of visible text
   ;
   NSAccessibilitySharedTextUIElementsAttribute	//(NSArray *)  - text views sharing text
   ;
   NSAccessibilitySharedCharacterRangeAttribute	//(NSValue *)  - (rangeValue) part of shared text in this view
   ;
   NSAccessibilityInsertionPointLineNumberAttribute	//(NSNumber *) - line# containing caret
   ;
   NSAccessibilitySelectedTextRangesAttribute	//(NSArray *) - array of NSValue (rangeValue) ranges of selected text
   ;


   /* Parameterized text-specific attributes
    */
   NSAccessibilityLineForIndexParameterizedAttribute		//(NSNumber *) - line# for char index; param:(NSNumber *)
   ;
   NSAccessibilityRangeForLineParameterizedAttribute		//(NSValue *)  - (rangeValue) range of line; param:(NSNumber *)
   ;
   NSAccessibilityStringForRangeParameterizedAttribute	//(NSString *) - substring; param:(NSValue * - rangeValue)
   ;
   NSAccessibilityRangeForPositionParameterizedAttribute	//(NSValue *)  - (rangeValue) composed char range; param:(NSValue * - pointValue)
   ;
   NSAccessibilityRangeForIndexParameterizedAttribute	//(NSValue *)  - (rangeValue) composed char range; param:(NSNumber *)
   ;
   NSAccessibilityBoundsForRangeParameterizedAttribute	//(NSValue *)  - (rectValue) bounds of text; param:(NSValue * - rangeValue)
   ;
   NSAccessibilityRTFForRangeParameterizedAttribute		//(NSData *)   - rtf for text; param:(NSValue * - rangeValue)
   ;
   NSAccessibilityStyleRangeForIndexParameterizedAttribute	//(NSValue *)  - (rangeValue) extent of style run; param:(NSNumber *)
   ;
   NSAccessibilityAttributedStringForRangeParameterizedAttribute //(NSAttributedString *) - does _not_ use attributes from Appkit/AttributedString.h
   ;


   /* Text attributed string attributes and constants
    */
   NSAccessibilityFontTextAttribute			//(NSDictionary *)  - NSAccessibilityFontXXXKey's
   ;
   NSAccessibilityForegroundColorTextAttribute	//CGColorRef
   ;
   NSAccessibilityBackgroundColorTextAttribute	//CGColorRef
   ;
   NSAccessibilityUnderlineColorTextAttribute	//CGColorRef
   ;
   NSAccessibilityStrikethroughColorTextAttribute	//CGColorRef
   ;
   NSAccessibilityUnderlineTextAttribute		//(NSNumber *)	    - underline style
   ;
   NSAccessibilitySuperscriptTextAttribute		//(NSNumber *)	    - superscript>0, subscript<0
   ;
   NSAccessibilityStrikethroughTextAttribute		//(NSNumber *)	    - (boolValue)
   ;
   NSAccessibilityShadowTextAttribute		//(NSNumber *)	    - (boolValue)
   ;
   NSAccessibilityAttachmentTextAttribute		//id - corresponding element
   ;
   NSAccessibilityLinkTextAttribute			//id - corresponding element
   ;
   NSAccessibilityMisspelledTextAttribute		//(NSNumber *)	    - (boolValue)
   ;

   NSAccessibilityFontNameKey	// required
   ;
   NSAccessibilityFontFamilyKey	// optional
   ;
   NSAccessibilityVisibleNameKey	// optional
   ;
   NSAccessibilityFontSizeKey	// required
   ;


   /* Window-specific attributes
    */
   NSAccessibilityMainAttribute;		//(NSNumber *) - (boolValue) is it the main window?
   NSAccessibilityMinimizedAttribute;	//(NSNumber *) - (boolValue) is window minimized?
   NSAccessibilityCloseButtonAttribute;	//(id) - UIElement for close box (or nil)
   NSAccessibilityZoomButtonAttribute;	//(id) - UIElement for zoom box (or nil)
   NSAccessibilityMinimizeButtonAttribute;	//(id) - UIElement for miniaturize box (or nil)
   NSAccessibilityToolbarButtonAttribute;	//(id) - UIElement for toolbar box (or nil)
   NSAccessibilityProxyAttribute;		//(id) - UIElement for title's icon (or nil)
   NSAccessibilityGrowAreaAttribute;		//(id) - UIElement for grow box (or nil)
   NSAccessibilityModalAttribute		//(NSNumber *) - (boolValue) is the window modal
   ;
   NSAccessibilityDefaultButtonAttribute	//(id) - UIElement for default button
   ;
   NSAccessibilityCancelButtonAttribute	//(id) - UIElement for cancel button
   ;

   /* Application-specific attributes
    */
   NSAccessibilityMenuBarAttribute;		//(id)         - UIElement for the menu bar
   NSAccessibilityWindowsAttribute;		//(NSArray *)  - UIElements for the windows
   NSAccessibilityFrontmostAttribute;	//(NSNumber *) - (boolValue) is the app active?
   NSAccessibilityHiddenAttribute;		//(NSNumber *) - (boolValue) is the app hidden?
   NSAccessibilityMainWindowAttribute;	//(id)         - UIElement for the main window.
   NSAccessibilityFocusedWindowAttribute;	//(id)         - UIElement for the key window.
   NSAccessibilityFocusedUIElementAttribute;	//(id)         - Currently focused UIElement.

   NSAccessibilityOrientationAttribute;	//(NSString *) - NSAccessibilityXXXOrientationValue
   NSAccessibilityVerticalOrientationValue;
   NSAccessibilityHorizontalOrientationValue;
   NSAccessibilityUnknownOrientationValue	;

   NSAccessibilityColumnTitlesAttribute;	//(NSArray *)  - UIElements for titles

   NSAccessibilitySearchButtonAttribute	//(id)         - UIElement for search field search btn
   ;
   NSAccessibilitySearchMenuAttribute	//(id)         - UIElement for search field menu
   ;
   NSAccessibilityClearButtonAttribute	//(id)         - UIElement for search field clear btn
   ;


   /* Table/outline view attributes
    */
   NSAccessibilityRowsAttribute;		//(NSArray *)  - UIElements for rows
   NSAccessibilityVisibleRowsAttribute;	//(NSArray *)  - UIElements for visible rows
   NSAccessibilitySelectedRowsAttribute;	//(NSArray *)  - UIElements for selected rows
   NSAccessibilityColumnsAttribute;		//(NSArray *)  - UIElements for columns
   NSAccessibilityVisibleColumnsAttribute;	//(NSArray *)  - UIElements for visible columns
   NSAccessibilitySelectedColumnsAttribute;	//(NSArray *)  - UIElements for selected columns
   NSAccessibilitySortDirectionAttribute	//(NSString *) - see sort direction values below
   ;

   /* Cell-based table attributes
    */
   NSAccessibilitySelectedCellsAttribute ;	//(NSArray *)  - UIElements for selected cells
   NSAccessibilityVisibleCellsAttribute ;	//(NSArray *)  - UIElements for visible cells
   NSAccessibilityRowHeaderUIElementsAttribute ;	//(NSArray *)  - UIElements for row headers
   NSAccessibilityColumnHeaderUIElementsAttribute ;	//(NSArray *)  - UIElements for column headers

   /* Cell-based table parameterized attributes.  The parameter for this attribute is an NSArray containing two NSNumbers, the first NSNumber specifies the column index, the second NSNumber specifies the row index.
    */
   NSAccessibilityCellForColumnAndRowParameterizedAttribute ;  // (id) - UIElement for cell at specified row and column

   /* Cell attributes.  The index range contains both the starting index, and the index span in a table.
    */
   NSAccessibilityRowIndexRangeAttribute ;	//(NSValue *)  - (rangeValue) location and row span
   NSAccessibilityColumnIndexRangeAttribute ;   //(NSValue *)  - (rangeValue) location and column span

   /* Layout area attributes
    */
   NSAccessibilityHorizontalUnitsAttribute ;   //(NSString *) - see ruler unit values below
   NSAccessibilityVerticalUnitsAttribute ;	    //(NSString *) - see ruler unit values below
   NSAccessibilityHorizontalUnitDescriptionAttribute ; //(NSString *)
   NSAccessibilityVerticalUnitDescriptionAttribute ;    //(NSString *)

   /* Layout area parameterized attributes
    */
   NSAccessibilityLayoutPointForScreenPointParameterizedAttribute ; //(NSValue *)  - (pointValue); param:(NSValue * - pointValue)
   NSAccessibilityLayoutSizeForScreenSizeParameterizedAttribute ; //(NSValue *)  - (sizeValue); param:(NSValue * - sizeValue)
   NSAccessibilityScreenPointForLayoutPointParameterizedAttribute ; //(NSValue *)  - (pointValue); param:(NSValue * - pointValue)
   NSAccessibilityScreenSizeForLayoutSizeParameterizedAttribute ; //(NSValue *)  - (sizeValue); param:(NSValue * - sizeValue)

   /* Layout item attributes
    */
   NSAccessibilityHandlesAttribute ; //(NSArray *)  - UIElements for handles

   /* Sort direction values
    */
   NSAccessibilityAscendingSortDirectionValue	;
   NSAccessibilityDescendingSortDirectionValue	;
   NSAccessibilityUnknownSortDirectionValue		;

   /* Outline attributes
    */
   NSAccessibilityDisclosingAttribute;	//(NSNumber *) - (boolValue) is diclosing rows?
   NSAccessibilityDisclosedRowsAttribute;	//(NSArray *)  - UIElements for disclosed rows
   NSAccessibilityDisclosedByRowAttribute;	//(id)         - UIElement for disclosing row
   NSAccessibilityDisclosureLevelAttribute	//(NSNumber *) - indentation level
   ;

   /* Slider attributes
    */
   NSAccessibilityAllowedValuesAttribute	//(NSArray *) - array of allowed values
   ;
   NSAccessibilityLabelUIElementsAttribute	//(NSArray *) - array of label UIElements
   ;
   NSAccessibilityLabelValueAttribute	//(NSNumber *) - value of a label UIElement
   ;

   /* Matte attributes
    */
   NSAccessibilityMatteHoleAttribute		//(NSValue *) - (rect value) bounds of matte hole in screen coords
   ;
   NSAccessibilityMatteContentUIElementAttribute //(id) - UIElement clipped by the matte
   ;

   /* Ruler view attributes
    */
   NSAccessibilityMarkerUIElementsAttribute		//(NSArray *)
   ;
   NSAccessibilityMarkerValuesAttribute		//
   ;
   NSAccessibilityMarkerGroupUIElementAttribute	//(id)
   ;
   NSAccessibilityUnitsAttribute			//(NSString *) - see ruler unit values below
   ;
   NSAccessibilityUnitDescriptionAttribute		//(NSString *)
   ;
   NSAccessibilityMarkerTypeAttribute		//(NSString *) - see ruler marker type values below
   ;
   NSAccessibilityMarkerTypeDescriptionAttribute	//(NSString *)
   ;

   /* Deprecated
    */
   NSAccessibilityHorizontialUnitsAttribute ;
   NSAccessibilityHorizontialUnitDescriptionAttribute ;
#endif

}

NSArray *wxOSX_accessibilityAttributeNames( id self, SEL _cmd )
{
   // Pass-through first
   typedef NSArray *(*Function)(id, SEL);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   NSArray *result = superimpl(self, _cmd);

   // Add more attributes
   wxAccessible *accessible = findAccessible( self );
   if (accessible)
      return findAttributeNames( self, *accessible, wxACC_SELF, result );

   return result;
}

id wxOSX_accessibilityAttributeValue( id self, SEL _cmd, NSString *attribute )
{
   // If attribute is defined for the wxAccessible object, that takes precedence
   wxAccessible *accessible = findAccessible( self );
   if (accessible)
   {
      const wxNSAccessibilityAttribute *pAttribute =
         findAttribute(self, attribute);
      if (pAttribute && pAttribute->IsPresent(self, *accessible, wxACC_SELF))
         return pAttribute->Get(self, *accessible, wxACC_SELF);
   }

   // Otherwise, pass-through
   typedef id (*Function)(id, SEL, NSString *);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   id result = superimpl(self, _cmd, attribute);
   return result;
}

BOOL wxOSX_accessibilityIsAttributeSettable( id self, SEL _cmd, NSString *attribute )
{
   // If attribute is defined for the wxAccessible object, that takes precedence
   wxAccessible *accessible = findAccessible( self );
   if (accessible)
   {
      const wxNSAccessibilityAttribute *pAttribute =
         findAttribute(self, attribute);
      if (pAttribute && pAttribute->IsPresent(self, *accessible, wxACC_SELF))
         return pAttribute->IsSettable(self, *accessible, wxACC_SELF);
   }

   // Otherwise, pass-through
   typedef BOOL (*Function)(id, SEL, NSString *);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   BOOL result = superimpl(self, _cmd, attribute);
   return result;
}

void wxOSX_accessibilitySetValue_forAttribute( id self, SEL _cmd, id value, NSString *attribute )
{
   // If attribute is defined for the wxAccessible object, that takes precedence
   wxAccessible *accessible = findAccessible( self );
   if (accessible)
   {
      const wxNSAccessibilityAttribute *pAttribute =
         findAttribute(self, attribute);
      if (pAttribute && pAttribute->IsPresent(self, *accessible, wxACC_SELF))
      {
         if (pAttribute->IsSettable(self, *accessible, wxACC_SELF))
            pAttribute->Set(self, *accessible, wxACC_SELF, value);
         return;
      }
   }

   // Otherwise, pass-through
   typedef void (*Function)(id, SEL, id, NSString *);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   superimpl(self, _cmd, value, attribute);
}

NSArray *wxOSX_accessibilityParameterizedAttributeNames( id self, SEL _cmd )
{
   typedef NSArray *(*Function)(id, SEL);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   NSArray *result = superimpl(self, _cmd);
   return result;
}

id wxOSX_accessibilityAttributeValue_forParameter
   ( id self, SEL _cmd, NSString *attribute, id parameter )
{
   typedef id (*Function)(id, SEL, NSString*, id);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   id result = superimpl(self, _cmd, attribute, parameter);
   return result;
}

NSArray *wxOSX_accessibilityActionNames( id self, SEL _cmd )
{
#if 0
   /* Actions
    */
NSAccessibilityPressAction;
NSAccessibilityIncrementAction;
NSAccessibilityDecrementAction;
NSAccessibilityConfirmAction;
NSAccessibilityPickAction;
NSAccessibilityCancelAction;
NSAccessibilityRaiseAction;
NSAccessibilityShowMenuAction;
NSAccessibilityDeleteAction;
#endif

   // This function produces an array of standard action string keys, which are
   // not localized action descriptions.  So wxAccessible::GetDefaultAction()
   // is not what we want.

   // So in default of a better thing to do,
   // we just give everything one press action, and only in case a default
   // action is defined.
   wxAccessible *pAccessible = findAccessible(self);
   if (pAccessible)
   {
      wxString unused;
      wxAccStatus status = pAccessible->GetDefaultAction(wxACC_SELF, &unused);
      if (status == wxACC_OK)
      {
         return [NSArray arrayWithObject: NSAccessibilityPressAction];
      }
   }

   typedef NSArray *(*Function)(id, SEL);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   NSArray *result = superimpl(self, _cmd);
   return result;
}

NSString *wxOSX_accessibilityActionDescription( id self, SEL _cmd, NSString *action )
{
   NSString *result = NSAccessibilityActionDescription(action);
   if (result)
      return result;

   typedef NSString *(*Function)(id, SEL, NSString*);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   result = superimpl(self, _cmd, action);
   return result;
}

void wxOSX_accessibilityPerformAction( id self, SEL _cmd, NSString *action )
{
   wxAccessible *pAccessible = findAccessible(self);
   if (pAccessible)
   {
      wxAccStatus status = pAccessible->DoDefaultAction(wxACC_SELF);
      if (status == wxACC_OK)
         return;
   }

   typedef void (*Function)(id, SEL, NSString*);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   superimpl(self, _cmd, action);
}

BOOL wxOSX_accessibilityIsIgnored( id self, SEL _cmd )
{
   wxAccessible *pAccessible = findAccessible(self);
   if (pAccessible)
      return NO;

   typedef BOOL (*Function)(id, SEL);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   BOOL result = superimpl(self, _cmd);
   return result;
}

id wxOSX_accessibilityHitTest( id self, SEL _cmd, NSPoint point )
{
   typedef id (*Function)(id, SEL, NSPoint);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   id result = superimpl(self, _cmd, point);
   return result;
}

id wxOSX_accessibilityFocusedUIElement( id self, SEL _cmd )
{
   typedef id (*Function)(id, SEL);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   id result = superimpl(self, _cmd);
   return result;
}

NSUInteger wxOSX_accessibilityIndexOfChild( id self, SEL _cmd, id child )
{
   wxAccessible *accessible = findAccessible( self );
   if (accessible)
   {
      return swxNSAccessibilityChildrenAttribute
         .IndexOfValue(self, *accessible, wxACC_SELF, child);
   }

   typedef NSUInteger (*Function)(id, SEL, id);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   NSUInteger result = superimpl(self, _cmd, child);
   return result;
}

NSUInteger wxOSX_accessibilityArrayAttributeCount( id self, SEL _cmd, NSString *attribute )
{
   // If attribute is defined for the wxAccessible object, that takes precedence
   wxAccessible *accessible = findAccessible( self );
   if (accessible)
   {
      const wxNSAccessibilityAttribute *pAttribute =
      findAttribute(self, attribute);
      if (pAttribute && pAttribute->IsPresent(self, *accessible, wxACC_SELF))
      {
         const wxNSAccessibilityArrayAttribute *pArrayAttribute =
            dynamic_cast<const wxNSAccessibilityArrayAttribute*>(pAttribute);
         if (pArrayAttribute)
         {
            return pArrayAttribute->GetCount(self, *accessible, wxACC_SELF);
         }
      }
   }

   // Otherwise, pass-through
   typedef NSUInteger (*Function)(id, SEL, NSString *);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   NSUInteger result = superimpl(self, _cmd, attribute);
   return result;
}

NSArray *wxOSX_accessibilityArrayAttributeValues_index_maxCount
   ( id self, SEL _cmd, NSString *attribute, NSUInteger index, NSUInteger maxCount )
{
   // If attribute is defined for the wxAccessible object, that takes precedence
   wxAccessible *accessible = findAccessible( self );
   if (accessible)
   {
      const wxNSAccessibilityAttribute *pAttribute =
      findAttribute(self, attribute);
      if (pAttribute && pAttribute->IsPresent(self, *accessible, wxACC_SELF))
      {
         const wxNSAccessibilityArrayAttribute *pArrayAttribute =
         dynamic_cast<const wxNSAccessibilityArrayAttribute*>(pAttribute);
         if (pArrayAttribute)
         {
            return pArrayAttribute->GetValues
               (self, *accessible, wxACC_SELF, index, maxCount);
         }
      }
   }

   // Otherwise, pass-through
   typedef NSArray *(*Function)(id, SEL, NSString *, NSUInteger, NSUInteger);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   NSArray *result = superimpl(self, _cmd, attribute, index, maxCount);
   return result;
}

BOOL wxOSX_accessibilitySetOverrideValue_forAttribute( id self, SEL _cmd, NSString *attribute )
{
   typedef BOOL (*Function)(id, SEL, NSString *);
   Function superimpl = (Function)
      [[self superclass] instanceMethodForSelector:_cmd];
   BOOL result = superimpl(self, _cmd, attribute);
   return result;
}


#endif

NSString* wxOSX_stringValue(id self, SEL _cmd)
{
   if ([[self superclass] instancesRespondToSelector: _cmd])
   {
      typedef NSString* (*Function)(id, SEL);
      Function superimpl = (Function)
         [[self superclass] instanceMethodForSelector:_cmd];
      return superimpl(self, _cmd);
   }
   else
      return @"";
}

void wxOSX_mouseEvent(NSView* self, SEL _cmd, NSEvent *event)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return;

    impl->mouseEvent(event, self, _cmd);
}

void wxOSX_cursorUpdate(NSView* self, SEL _cmd, NSEvent *event)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return;
    
    impl->cursorUpdate(event, self, _cmd);
}

BOOL wxOSX_acceptsFirstMouse(NSView* WXUNUSED(self), SEL WXUNUSED(_cmd), NSEvent *WXUNUSED(event))
{
    // This is needed to support click through, otherwise the first click on a window
    // will not do anything unless it is the active window already.
    return YES;
}

void wxOSX_keyEvent(NSView* self, SEL _cmd, NSEvent *event)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return;

    impl->keyEvent(event, self, _cmd);
}

void wxOSX_insertText(NSView* self, SEL _cmd, NSString* text)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return;

    impl->insertText(text, self, _cmd);
}

BOOL wxOSX_performKeyEquivalent(NSView* self, SEL _cmd, NSEvent *event)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NO;

    return impl->performKeyEquivalent(event, self, _cmd);
}

BOOL wxOSX_acceptsFirstResponder(NSView* self, SEL _cmd)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NO;

    return impl->acceptsFirstResponder(self, _cmd);
}

BOOL wxOSX_becomeFirstResponder(NSView* self, SEL _cmd)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NO;

    return impl->becomeFirstResponder(self, _cmd);
}

BOOL wxOSX_resignFirstResponder(NSView* self, SEL _cmd)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NO;

    return impl->resignFirstResponder(self, _cmd);
}

#if !wxOSX_USE_NATIVE_FLIPPED

BOOL wxOSX_isFlipped(NSView* self, SEL _cmd)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return NO;

    return impl->isFlipped(self, _cmd) ? YES:NO;
}

#endif

typedef void (*wxOSX_DrawRectHandlerPtr)(NSView* self, SEL _cmd, NSRect rect);

void wxOSX_drawRect(NSView* self, SEL _cmd, NSRect rect)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return;

#if wxUSE_THREADS
    // OS X starts a NSUIHeartBeatThread for animating the default button in a
    // dialog. This causes a drawRect of the active dialog from outside the
    // main UI thread. This causes an occasional crash since the wx drawing
    // objects (like wxPen) are not thread safe.
    //
    // Notice that NSUIHeartBeatThread seems to be undocumented and doing
    // [NSWindow setAllowsConcurrentViewDrawing:NO] does not affect it.
    if ( !wxThread::IsMain() )
    {
        if ( impl->IsUserPane() )
        {
            wxWindow* win = impl->GetWXPeer();
            if ( win->UseBgCol() )
            {
                
                CGContextRef context = (CGContextRef) [[NSGraphicsContext currentContext] graphicsPort];
                CGContextSaveGState( context );

                CGContextSetFillColorWithColor( context, win->GetBackgroundColour().GetCGColor());
                CGRect r = CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
                CGContextFillRect( context, r );

                CGContextRestoreGState( context );
            }
        }
        else 
        {
            // just call the superclass handler, we don't need any custom wx drawing
            // here and it seems to work fine:
            wxOSX_DrawRectHandlerPtr
            superimpl = (wxOSX_DrawRectHandlerPtr)
            [[self superclass] instanceMethodForSelector:_cmd];
            superimpl(self, _cmd, rect);
        }

      return;
    }
#endif // wxUSE_THREADS

    return impl->drawRect(&rect, self, _cmd);
}

void wxOSX_controlAction(NSView* self, SEL _cmd, id sender)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return;

    impl->controlAction(self, _cmd, sender);
}

void wxOSX_controlDoubleAction(NSView* self, SEL _cmd, id sender)
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl == NULL)
        return;

    impl->controlDoubleAction(self, _cmd, sender);
}

#if wxUSE_DRAG_AND_DROP
unsigned int wxWidgetCocoaImpl::draggingEntered(void* s, WXWidget WXUNUSED(slf), void *WXUNUSED(_cmd))
{
    id <NSDraggingInfo>sender = (id <NSDraggingInfo>) s;
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];

    wxWindow* wxpeer = GetWXPeer();
    if ( wxpeer == NULL )
        return NSDragOperationNone;

    wxDropTarget* target = wxpeer->GetDropTarget();
    if ( target == NULL )
        return NSDragOperationNone;

    wxDragResult result = wxDragNone;
    NSPoint nspoint = [m_osxView convertPoint:[sender draggingLocation] fromView:nil];
    wxPoint pt = wxFromNSPoint( m_osxView, nspoint );

    if ( sourceDragMask & NSDragOperationLink )
        result = wxDragLink;
    else if ( sourceDragMask & NSDragOperationCopy )
        result = wxDragCopy;
    else if ( sourceDragMask & NSDragOperationMove )
        result = wxDragMove;

    PasteboardRef pboardRef;
    PasteboardCreate((CFStringRef)[pboard name], &pboardRef);
    target->SetCurrentDragPasteboard(pboardRef);
    result = target->OnEnter(pt.x, pt.y, result);
    CFRelease(pboardRef);

    NSDragOperation nsresult = NSDragOperationNone;
    switch (result )
    {
        case wxDragLink:
            nsresult = NSDragOperationLink;
        case wxDragMove:
            nsresult = NSDragOperationMove;
        case wxDragCopy:
            nsresult = NSDragOperationCopy;
        default :
            break;
    }
    return nsresult;
}

void wxWidgetCocoaImpl::draggingExited(void* s, WXWidget WXUNUSED(slf), void *WXUNUSED(_cmd))
{
    id <NSDraggingInfo>sender = (id <NSDraggingInfo>) s;
    NSPasteboard *pboard = [sender draggingPasteboard];

    wxWindow* wxpeer = GetWXPeer();
    if ( wxpeer == NULL )
        return;

    wxDropTarget* target = wxpeer->GetDropTarget();
    if ( target == NULL )
        return;

    PasteboardRef pboardRef;
    PasteboardCreate((CFStringRef)[pboard name], &pboardRef);
    target->SetCurrentDragPasteboard(pboardRef);
    target->OnLeave();
    CFRelease(pboardRef);
 }

unsigned int wxWidgetCocoaImpl::draggingUpdated(void* s, WXWidget WXUNUSED(slf), void *WXUNUSED(_cmd))
{
    id <NSDraggingInfo>sender = (id <NSDraggingInfo>) s;
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];

    wxWindow* wxpeer = GetWXPeer();
    if ( wxpeer == NULL )
        return NSDragOperationNone;

    wxDropTarget* target = wxpeer->GetDropTarget();
    if ( target == NULL )
        return NSDragOperationNone;

    wxDragResult result = wxDragNone;
    NSPoint nspoint = [m_osxView convertPoint:[sender draggingLocation] fromView:nil];
    wxPoint pt = wxFromNSPoint( m_osxView, nspoint );

    if ( sourceDragMask & NSDragOperationLink )
        result = wxDragLink;
    else if ( sourceDragMask & NSDragOperationCopy )
        result = wxDragCopy;
    else if ( sourceDragMask & NSDragOperationMove )
        result = wxDragMove;
    
    PasteboardRef pboardRef;
    PasteboardCreate((CFStringRef)[pboard name], &pboardRef);
    target->SetCurrentDragPasteboard(pboardRef);
    result = target->OnDragOver(pt.x, pt.y, result);
    CFRelease(pboardRef);

    NSDragOperation nsresult = NSDragOperationNone;
    switch (result )
    {
        case wxDragLink:
            nsresult = NSDragOperationLink;
        case wxDragMove:
            nsresult = NSDragOperationMove;
        case wxDragCopy:
            nsresult = NSDragOperationCopy;
        default :
            break;
    }
    return nsresult;
}

bool wxWidgetCocoaImpl::performDragOperation(void* s, WXWidget WXUNUSED(slf), void *WXUNUSED(_cmd))
{
    id <NSDraggingInfo>sender = (id <NSDraggingInfo>) s;

    NSPasteboard *pboard = [sender draggingPasteboard];
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];

    wxWindow* wxpeer = GetWXPeer();
    wxDropTarget* target = wxpeer->GetDropTarget();
    wxDragResult result = wxDragNone;
    NSPoint nspoint = [m_osxView convertPoint:[sender draggingLocation] fromView:nil];
    wxPoint pt = wxFromNSPoint( m_osxView, nspoint );

    if ( sourceDragMask & NSDragOperationLink )
        result = wxDragLink;
    else if ( sourceDragMask & NSDragOperationCopy )
        result = wxDragCopy;
    else if ( sourceDragMask & NSDragOperationMove )
        result = wxDragMove;

    PasteboardRef pboardRef;
    PasteboardCreate((CFStringRef)[pboard name], &pboardRef);
    target->SetCurrentDragPasteboard(pboardRef);

    if (target->OnDrop(pt.x, pt.y))
        result = target->OnData(pt.x, pt.y, result);

    CFRelease(pboardRef);

    return result != wxDragNone;
}
#endif // wxUSE_DRAG_AND_DROP

void wxWidgetCocoaImpl::mouseEvent(WX_NSEvent event, WXWidget slf, void *_cmd)
{
    // we are getting moved events for all windows in the hierarchy, not something wx expects
    // therefore we only handle it for the deepest child in the hierarchy
    if ( [event type] == NSMouseMoved )
    {
        NSView* hitview = [[[slf window] contentView] hitTest:[event locationInWindow]];
        if ( hitview == NULL || hitview != slf)
            return;
    }
    
    if ( !DoHandleMouseEvent(event) )
    {
        // for plain NSView mouse events would propagate to parents otherwise
        // scrollwheel events have to be propagated if not handled in all cases
        if (!IsUserPane() || [event type] == NSScrollWheel )
        {
            wxOSX_EventHandlerPtr superimpl = (wxOSX_EventHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
            superimpl(slf, (SEL)_cmd, event);
            
            // super of built-ins keeps the mouse up, as wx expects this event, we have to synthesize it
            // only trigger if at this moment the mouse is already up, and the control is still existing after the event has
            // been handled (we do this by looking up the native NSView's peer from the hash map, that way we are sure the info
            // is current - even when the instance memory of ourselves may have been freed ...
            
            wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( slf );
            if ( [ event type]  == NSLeftMouseDown && !wxGetMouseState().LeftIsDown() && impl != NULL )
            {
                wxMouseEvent wxevent(wxEVT_LEFT_DOWN);
                SetupMouseEvent(wxevent , event) ;
                wxevent.SetEventType(wxEVT_LEFT_UP);
                
                GetWXPeer()->HandleWindowEvent(wxevent);
            }
        }
    }
}

void wxWidgetCocoaImpl::cursorUpdate(WX_NSEvent event, WXWidget slf, void *_cmd)
{
    if ( !SetupCursor(event) )
    {
        wxOSX_EventHandlerPtr superimpl = (wxOSX_EventHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
            superimpl(slf, (SEL)_cmd, event);
    }
 }

bool wxWidgetCocoaImpl::SetupCursor(WX_NSEvent event)
{
    extern wxCursor gGlobalCursor;
    
    if ( gGlobalCursor.IsOk() )
    {
        gGlobalCursor.MacInstall();
        return true;
    }
    else
    {
        wxWindow* cursorTarget = GetWXPeer();
        wxCoord x,y;
        SetupCoordinates(x, y, event);
        wxPoint cursorPoint( x , y ) ;
        
        while ( cursorTarget && !cursorTarget->MacSetupCursor( cursorPoint ) )
        {
            // at least in GTK cursor events are not propagated either ...
#if 1
            cursorTarget = NULL;
#else
            cursorTarget = cursorTarget->GetParent() ;
            if ( cursorTarget )
                cursorPoint += cursorTarget->GetPosition();
#endif
        }
        
        return cursorTarget != NULL;
    }
}

void wxWidgetCocoaImpl::keyEvent(WX_NSEvent event, WXWidget slf, void *_cmd)
{
    if ( [event type] == NSKeyDown )
    {
        // there are key equivalents that are not command-combos and therefore not handled by cocoa automatically, 
        // therefore we call the menubar directly here, exit if the menu is handling the shortcut
        if ( [[[NSApplication sharedApplication] mainMenu] performKeyEquivalent:event] )
            return;
    
        m_lastKeyDownEvent = event;
    }
    
    if ( GetFocusedViewInWindow([slf window]) != slf || m_hasEditor || !DoHandleKeyEvent(event) )
    {
        wxOSX_EventHandlerPtr superimpl = (wxOSX_EventHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
        superimpl(slf, (SEL)_cmd, event);
    }
    m_lastKeyDownEvent = NULL;
}

void wxWidgetCocoaImpl::insertText(NSString* text, WXWidget slf, void *_cmd)
{
    bool result = false;
    if ( IsUserPane() && !m_hasEditor && [text length] > 0)
    {
        if ( m_lastKeyDownEvent!=NULL && [text isEqualToString:[m_lastKeyDownEvent characters]])
        {
            // If we have a corresponding key event, send wxEVT_KEY_DOWN now.
            // (see also: wxWidgetCocoaImpl::DoHandleKeyEvent)
            {
                wxKeyEvent wxevent(wxEVT_KEY_DOWN);
                SetupKeyEvent( wxevent, m_lastKeyDownEvent );
                result = GetWXPeer()->OSXHandleKeyEvent(wxevent);
            }

            // ...and wxEVT_CHAR.
            result = result || DoHandleCharEvent(m_lastKeyDownEvent, text);
        }
        else
        {
            // If we don't have a corresponding key event (e.g. IME-composed
            // characters), send wxEVT_CHAR without sending wxEVT_KEY_DOWN.
            for (NSUInteger i = 0; i < [text length]; ++i)
            {
                wxKeyEvent wxevent(wxEVT_CHAR);
                wxevent.m_shiftDown = wxevent.m_controlDown = wxevent.m_altDown = wxevent.m_metaDown = false;
                wxevent.m_rawCode = 0;
                wxevent.m_rawFlags = 0;
                wxevent.SetTimestamp();
                unichar aunichar = [text characterAtIndex:i];
#if wxUSE_UNICODE
                wxevent.m_uniChar = aunichar;
#endif
                wxevent.m_keyCode = aunichar < 0x80 ? aunichar : WXK_NONE;
                wxWindowMac* peer = GetWXPeer();
                if ( peer )
                {
                    wxevent.SetEventObject(peer);
                    wxevent.SetId(peer->GetId());
                }
                result = GetWXPeer()->OSXHandleKeyEvent(wxevent) || result;
            }
        }
    }
    if ( !result )
    {
        wxOSX_TextEventHandlerPtr superimpl = (wxOSX_TextEventHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
        superimpl(slf, (SEL)_cmd, text);
    }
}

void wxWidgetCocoaImpl::doCommandBySelector(void* sel, WXWidget slf, void* _cmd)
{
    if ( m_lastKeyDownEvent!=NULL )
    {
        // If we have a corresponding key event, send wxEVT_KEY_DOWN now.
        // (see also: wxWidgetCocoaImpl::DoHandleKeyEvent)
        wxKeyEvent wxevent(wxEVT_KEY_DOWN);
        SetupKeyEvent( wxevent, m_lastKeyDownEvent );
        bool result = GetWXPeer()->OSXHandleKeyEvent(wxevent);

        if (!result)
        {
            // Generate wxEVT_CHAR if wxEVT_KEY_DOWN is not handled.

            long keycode = wxOSXTranslateCocoaKey( m_lastKeyDownEvent, wxEVT_CHAR );

            wxKeyEvent wxevent2(wxevent) ;
            wxevent2.SetEventType(wxEVT_CHAR);
            SetupKeyEvent( wxevent2, m_lastKeyDownEvent );
            if ( (keycode > 0 && keycode < WXK_SPACE) || keycode == WXK_DELETE || keycode >= WXK_START )
            {
                wxevent2.m_keyCode = keycode;
            }
            GetWXPeer()->OSXHandleKeyEvent(wxevent2);
        }
    }
}

bool wxWidgetCocoaImpl::performKeyEquivalent(WX_NSEvent event, WXWidget slf, void *_cmd)
{
    bool handled = false;
    
    wxKeyEvent wxevent(wxEVT_KEY_DOWN);
    SetupKeyEvent( wxevent, event );
   
    // because performKeyEquivalent is going up the entire view hierarchy, we don't have to
    // walk up the ancestors ourselves but let cocoa do it
    
    int command = m_wxPeer->GetAcceleratorTable()->GetCommand( wxevent );
    if (command != -1)
    {
        wxEvtHandler * const handler = m_wxPeer->GetEventHandler();
        
        wxCommandEvent command_event( wxEVT_MENU, command );
        command_event.SetEventObject( wxevent.GetEventObject() );
        handled = handler->ProcessEvent( command_event );
        
        if ( !handled )
        {
            // accelerators can also be used with buttons, try them too
            command_event.SetEventType(wxEVT_BUTTON);
            handled = handler->ProcessEvent( command_event );
        }
    }
    
    if ( !handled )
    {
        wxOSX_PerformKeyEventHandlerPtr superimpl = (wxOSX_PerformKeyEventHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
        return superimpl(slf, (SEL)_cmd, event);
    }
    return YES;
}

bool wxWidgetCocoaImpl::acceptsFirstResponder(WXWidget slf, void *_cmd)
{
    if ( IsUserPane() )
        return m_wxPeer->AcceptsFocus();
    else
    {
        wxOSX_FocusHandlerPtr superimpl = (wxOSX_FocusHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
        return superimpl(slf, (SEL)_cmd);
    }
}

bool wxWidgetCocoaImpl::becomeFirstResponder(WXWidget slf, void *_cmd)
{
    wxOSX_FocusHandlerPtr superimpl = (wxOSX_FocusHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
    BOOL r = superimpl(slf, (SEL)_cmd);
    if ( r )
        DoNotifyFocusSet();

    return r;
}

bool wxWidgetCocoaImpl::resignFirstResponder(WXWidget slf, void *_cmd)
{
    wxOSX_FocusHandlerPtr superimpl = (wxOSX_FocusHandlerPtr) [[slf superclass] instanceMethodForSelector:(SEL)_cmd];
    BOOL r = superimpl(slf, (SEL)_cmd);
    
    // wxNSTextFields and wxNSComboBoxes have an editor as real responder, therefore they get
    // a resign notification when their editor takes over, don't trigger  event here, the control
    // gets a controlTextDidEndEditing notification which will send a focus kill.
    if ( r && !m_hasEditor)
        DoNotifyFocusLost();

    return r;
}

#if !wxOSX_USE_NATIVE_FLIPPED

bool wxWidgetCocoaImpl::isFlipped(WXWidget slf, void *WXUNUSED(_cmd))
{
    return m_isFlipped;
}

#endif

#define OSX_DEBUG_DRAWING 0

void wxWidgetCocoaImpl::drawRect(void* rect, WXWidget slf, void *WXUNUSED(_cmd))
{
    // preparing the update region
    
    wxRegion updateRgn;

    // since adding many rects to a region is a costly process, by default use the bounding rect
#if 0
    const NSRect *rects;
    NSInteger count;
    [slf getRectsBeingDrawn:&rects count:&count];
    for ( int i = 0 ; i < count ; ++i )
    {
        updateRgn.Union(wxFromNSRect(slf, rects[i]));
    }
#else
    updateRgn.Union(wxFromNSRect(slf,*(NSRect*)rect));
#endif
    
    wxWindow* wxpeer = GetWXPeer();

    if ( wxpeer->MacGetLeftBorderSize() != 0 || wxpeer->MacGetTopBorderSize() != 0 )
    {
        // as this update region is in native window locals we must adapt it to wx window local
        updateRgn.Offset( wxpeer->MacGetLeftBorderSize() , wxpeer->MacGetTopBorderSize() );
    }
    
    // Restrict the update region to the shape of the window, if any, and also
    // remember the region that we need to clear later.
    wxNonOwnedWindow* const tlwParent = wxpeer->MacGetTopLevelWindow();
    const bool isTopLevel = tlwParent == wxpeer;
    wxRegion clearRgn;
    if ( tlwParent->GetWindowStyle() & wxFRAME_SHAPED )
    {
        wxRegion rgn = tlwParent->GetShape();
        if ( rgn.IsOk() )
        {
            if ( isTopLevel )
                clearRgn = updateRgn;

            int xoffset = 0, yoffset = 0;
            wxpeer->MacRootWindowToWindow( &xoffset, &yoffset );
            rgn.Offset( xoffset, yoffset );
            updateRgn.Intersect(rgn);

            if ( isTopLevel )
            {
                // Exclude the window shape from the region to be cleared below.
                rgn.Xor(wxpeer->GetSize());
                clearRgn.Intersect(rgn);
            }
        }
    }
    
    wxpeer->GetUpdateRegion() = updateRgn;

    // setting up the drawing context
    
    CGContextRef context = (CGContextRef) [[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState( context );
    
#if OSX_DEBUG_DRAWING
    CGContextBeginPath( context );
    CGContextMoveToPoint(context, 0, 0);
    NSRect bounds = [slf bounds];
    CGContextAddLineToPoint(context, 10, 0);
    CGContextMoveToPoint(context, 0, 0);
    CGContextAddLineToPoint(context, 0, 10);
    CGContextMoveToPoint(context, bounds.size.width, bounds.size.height);
    CGContextAddLineToPoint(context, bounds.size.width, bounds.size.height-10);
    CGContextMoveToPoint(context, bounds.size.width, bounds.size.height);
    CGContextAddLineToPoint(context, bounds.size.width-10, bounds.size.height);
    CGContextClosePath( context );
    CGContextStrokePath(context);
#endif
    
    if ( ![slf isFlipped] )
    {
        CGContextTranslateCTM( context, 0,  [m_osxView bounds].size.height );
        CGContextScaleCTM( context, 1, -1 );
    }
    
    wxpeer->MacSetCGContextRef( context );

    bool handled = wxpeer->MacDoRedraw( 0 );
    CGContextRestoreGState( context );

    CGContextSaveGState( context );
    if ( !handled )
    {
        // call super
        SEL _cmd = @selector(drawRect:);
        wxOSX_DrawRectHandlerPtr superimpl = (wxOSX_DrawRectHandlerPtr) [[slf superclass] instanceMethodForSelector:_cmd];

        wxWindow *peer = GetWXPeer();
        bool hasFocus = peer->HasFocus();
        if (hasFocus &&
             peer->NeedsFocusRing()) {
           superimpl(slf, _cmd, *(NSRect*)rect);

           // Paint it again, without text, causing focus halo to be
           // superimposed about all else
           HIThemeBeginFocus( context, kHIThemeFocusRingOnly, NULL );
           CGContextSetTextDrawingMode( context, kCGTextInvisible );
           superimpl(slf, _cmd, *(NSRect*)rect);
           HIThemeEndFocus( context );
           
           CGContextRestoreGState( context );
           CGContextSaveGState( context );
        }
        else
           superimpl(slf, _cmd, *(NSRect*)rect);

        CGContextRestoreGState( context );
        CGContextSaveGState( context );
    }
    // as we called restore above, we have to flip again if necessary
    if ( ![slf isFlipped] )
    {
        CGContextTranslateCTM( context, 0,  [m_osxView bounds].size.height );
        CGContextScaleCTM( context, 1, -1 );
    }

    if ( isTopLevel )
    {
        // We also need to explicitly draw the part of the top level window
        // outside of its region with transparent colour to ensure that it is
        // really transparent.
        if ( clearRgn.IsOk() )
        {
            wxMacCGContextStateSaver saveState(context);
            wxWindowDC dc(wxpeer);
            dc.SetBackground(wxBrush(wxTransparentColour));
            dc.SetDeviceClippingRegion(clearRgn);
            dc.Clear();
        }

#if wxUSE_GRAPHICS_CONTEXT
        // If the window shape is defined by a path, stroke the path to show
        // the window border.
        const wxGraphicsPath& path = tlwParent->GetShapePath();
        if ( !path.IsNull() )
        {
            CGContextSetLineWidth(context, 1);
            CGContextSetStrokeColorWithColor(context, wxLIGHT_GREY->GetCGColor());
            CGContextAddPath(context, (CGPathRef) path.GetNativePath());
            CGContextStrokePath(context);
        }
#endif // wxUSE_GRAPHICS_CONTEXT
    }

    wxpeer->MacPaintChildrenBorders();
    wxpeer->MacSetCGContextRef( NULL );
    CGContextRestoreGState( context );
}

void wxWidgetCocoaImpl::controlAction( WXWidget WXUNUSED(slf), void *WXUNUSED(_cmd), void *WXUNUSED(sender))
{
    wxWindow* wxpeer = (wxWindow*) GetWXPeer();
    if ( wxpeer )
    {
        wxpeer->OSXSimulateFocusEvents();
        wxpeer->OSXHandleClicked(0);
    }
}

void wxWidgetCocoaImpl::controlDoubleAction( WXWidget WXUNUSED(slf), void *WXUNUSED(_cmd), void *WXUNUSED(sender))
{
}

void wxWidgetCocoaImpl::controlTextDidChange()
{
    wxWindow* wxpeer = (wxWindow*)GetWXPeer();
    if ( wxpeer ) 
    {
        // since native rtti doesn't have to be enabled and wx' rtti is not aware of the mixin wxTextEntry, workaround is needed
        wxTextCtrl *tc = wxDynamicCast( wxpeer , wxTextCtrl );
        wxComboBox *cb = wxDynamicCast( wxpeer , wxComboBox );
        if ( tc )
            tc->SendTextUpdatedEventIfAllowed();
        else if ( cb )
            cb->SendTextUpdatedEventIfAllowed();
        else 
        {
            wxFAIL_MSG("Unexpected class for controlTextDidChange event");
        }
    }
}

//

#if OBJC_API_VERSION >= 2

#define wxOSX_CLASS_ADD_METHOD( c, s, i, t ) \
    class_addMethod(c, s, i, t );

#else

#define wxOSX_CLASS_ADD_METHOD( c, s, i, t ) \
    { s, (char*) t, i },

#endif

@implementation wxAccessibilityChild
- (id)initWithAccessible: (wxAccessible*) accessible_
                  andNumber: (NSInteger) number_
{
   self = [super init];
   accessible = accessible_;
   number = number_;
   return self;
}

+ (id)accessibilityChildWithAccessible: (wxAccessible*)accessible_
                             andNumber: (NSInteger)number_;
{
   return [
      [[wxAccessibilityChild alloc]
          initWithAccessible: accessible_ andNumber: number_]
      autorelease
   ];
}

- (NSString*)stringValue
{
   // For debugging
   return @"";
}

- (BOOL)isEqual:(id)object
{
   if ([object isMemberOfClass: [wxAccessibilityChild class]])
   {
      wxAccessibilityChild *other = (wxAccessibilityChild*)object;
      if (accessible == other->accessible && number == other->number)
         return YES;
   }
   return NO;
}

// Implement the NSObject (NSAccessibility) informal protocol with appropriate
// forwards to the wxAccessible object

/* Attribute methods
 */
- (NSArray *)accessibilityAttributeNames
{
   return findAttributeNames( self, *accessible, number, NULL );
}

- (id)accessibilityAttributeValue:(NSString *)attribute
{
   const wxNSAccessibilityAttribute *pAttribute =
      findAttribute(self, attribute);
   if (pAttribute && pAttribute->IsPresent(self, *accessible, number))
      return pAttribute->Get(self, *accessible, number);
   return [super accessibilityAttributeValue: attribute];
}

- (BOOL)accessibilityIsAttributeSettable:(NSString *)attribute
{
   const wxNSAccessibilityAttribute *pAttribute =
      findAttribute(self, attribute);
   if (pAttribute && pAttribute->IsPresent(self, *accessible, number))
      return pAttribute->IsSettable(self, *accessible, number);
   return [super accessibilityIsAttributeSettable: attribute];
}

- (void)accessibilitySetValue:(id)value forAttribute:(NSString *)attribute
{
   const wxNSAccessibilityAttribute *pAttribute =
      findAttribute(self, attribute);
   if (pAttribute && pAttribute->IsPresent(self, *accessible, number))
   {
      if (pAttribute->IsSettable(self, *accessible, number))
         pAttribute->Set(self, *accessible, number, value);
      return;
   }

   [super accessibilitySetValue: value forAttribute: attribute];
}

/* Parameterized Attribute methods
 */
- (NSArray *)accessibilityParameterizedAttributeNames
{
   return [super accessibilityParameterizedAttributeNames];
}

- (id)accessibilityAttributeValue:(NSString *)attribute forParameter:(id)parameter
{
   return [super accessibilityAttributeValue: attribute forParameter: parameter];
}

/* Acessibility action methods
 */
- (NSArray *)accessibilityActionNames
{
   // see comments in wxOSX_accessibilityActionNames
   wxString unused;
   wxAccStatus status = accessible->GetDefaultAction(number, &unused);
   if (status == wxACC_OK)
   {
      return [NSArray arrayWithObject: NSAccessibilityPressAction];
   }

   if ([[self superclass] instancesRespondToSelector:
        @selector(accessibilityActionNames)])
      return [super accessibilityActionNames];
   return [NSArray array];
}

- (NSString *)accessibilityActionDescription:(NSString *)action
{
   NSString *result = NSAccessibilityActionDescription(action);
   if (result)
      return result;

   return [super accessibilityActionDescription: action];
}

- (void)accessibilityPerformAction:(NSString *)action
{
   wxAccStatus status = accessible->DoDefaultAction(number);
   if (status == wxACC_OK)
      return;

   [super accessibilityPerformAction: action];
}

/* Return YES if the UIElement doesn't show up to the outside world - i.e. its parent should return the UIElement's children as its own - cutting the UIElement out. E.g. NSControls are ignored when they are single-celled.
 */
- (BOOL)accessibilityIsIgnored
{
   return NO;
}

/* Returns the deepest descendant of the UIElement hierarchy that contains the point. You can assume the point has already been determined to lie within the receiver. Override this method to do deeper hit testing within a UIElement - e.g. a NSMatrix would test its cells. The point is bottom-left relative screen coordinates.
 */
- (id)accessibilityHitTest:(NSPoint)point
{
   return [super accessibilityHitTest: point];
}

/* Returns the UI Element that has the focus. You can assume that the search for the focus has already been narrowed down to the reciever. Override this method to do a deeper search with a UIElement - e.g. a NSMatrix would determine if one of its cells has the focus.
 */
- (id)accessibilityFocusedUIElement
{
   return [super accessibilityFocusedUIElement];
}


/*  Optional methods to improve performance of accessible objects with large numbers of children or large numbers of UI Elements returned from attributes that return an array (selected children, or visible children, for instance).  The default implementation for these operations will call -accessibilityAttributeValue: to retrieve the entire array of values, and then perform the appropriate operation.  If these methods are implemented, they will be used instead.  For accessibility objects with many children, the results to these methods can sometimes be calculated without generating the entire array of children which can improve performance.
 */

/* Given an accessibility child of an object, return the index of that child in the parent.
 */
- (NSUInteger)accessibilityIndexOfChild:(id)child
{
   return swxNSAccessibilityChildrenAttribute
      .IndexOfValue(self, *accessible, number, child);
}

/* Return the count of an accessibility array attribute.
 */
- (NSUInteger)accessibilityArrayAttributeCount:(NSString *)attribute
{
   // If attribute is defined for the wxAccessible object, that takes precedence
   const wxNSAccessibilityAttribute *pAttribute =
   findAttribute(self, attribute);
   if (pAttribute && pAttribute->IsPresent(self, *accessible, number))
   {
      const wxNSAccessibilityArrayAttribute *pArrayAttribute =
         dynamic_cast<const wxNSAccessibilityArrayAttribute*>(pAttribute);
      if (pArrayAttribute)
      {
         return pArrayAttribute->GetCount(self, *accessible, number);
      }
   }

   return [super accessibilityArrayAttributeCount: attribute];
}

/* Return a subarray of values of an accessibility array attribute.  Note this method does not take a range.  The max count is the maximum desired number of items requested by an accessibility client.  This number may be beyond the bounds of your array.
 */
- (NSArray *)accessibilityArrayAttributeValues:(NSString *)attribute
                                         index:(NSUInteger)index
                                      maxCount:(NSUInteger)maxCount
{
   // If attribute is defined for the wxAccessible object, that takes precedence
   const wxNSAccessibilityAttribute *pAttribute =
   findAttribute(self, attribute);
   if (pAttribute && pAttribute->IsPresent(self, *accessible, number))
   {
      const wxNSAccessibilityArrayAttribute *pArrayAttribute =
      dynamic_cast<const wxNSAccessibilityArrayAttribute*>(pAttribute);
      if (pArrayAttribute)
      {
         return pArrayAttribute->GetValues
            (self, *accessible, number, index, maxCount);
      }
   }

   return [super accessibilityArrayAttributeValues: attribute
                                             index: index
                                          maxCount: maxCount];
}

@end

void wxOSXCocoaClassAddWXAccessibilityMethods(Class c)
{
   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityAttributeNames), (IMP) wxOSX_accessibilityAttributeNames, "@@:" )
   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityAttributeValue:), (IMP) wxOSX_accessibilityAttributeValue, "@@:@" )
   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityIsAttributeSettable:), (IMP) wxOSX_accessibilityIsAttributeSettable, "c@:@" )
   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilitySetValue:forAttribute:), (IMP) wxOSX_accessibilitySetValue_forAttribute, "v@:@@" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityParameterizedAttributeNames), (IMP) wxOSX_accessibilityParameterizedAttributeNames, "@@:" )
   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityAttributeValue:forParameter:), (IMP) wxOSX_accessibilityAttributeValue_forParameter, "@@:@@" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityActionNames), (IMP) wxOSX_accessibilityActionNames, "@@:" )
   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityActionDescription:), (IMP) wxOSX_accessibilityActionDescription, "@@:@" )
   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityPerformAction:), (IMP) wxOSX_accessibilityPerformAction, "v@:@" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityIsIgnored), (IMP) wxOSX_accessibilityIsIgnored, "c@:" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityHitTest:), (IMP) wxOSX_accessibilityHitTest, "@@:{_NSPoint=ff}" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityFocusedUIElement), (IMP) wxOSX_accessibilityFocusedUIElement, "@@:" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityIndexOfChild:), (IMP) wxOSX_accessibilityIndexOfChild, "I@:@" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityArrayAttributeCount:), (IMP) wxOSX_accessibilityArrayAttributeCount, "I@:@" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilityArrayAttributeValues:index:maxCount:), (IMP) wxOSX_accessibilityArrayAttributeValues_index_maxCount, "@@:@II" )

   wxOSX_CLASS_ADD_METHOD(c, @selector(accessibilitySetOverrideValue:forAttribute:), (IMP) wxOSX_accessibilitySetOverrideValue_forAttribute, "c@:@@" )
}

// static
void wxAccessible::NotifyEvent
(int eventType, wxWindow* window, wxAccObject objectType, int objectId)
{
#if 0
   // Leftover NSAccessibility notifications that didn't correspond

   /* Focus notifications
    */
NSAccessibilityMainWindowChangedNotification;

   /* Application notifications
    */
NSAccessibilityApplicationActivatedNotification;
NSAccessibilityApplicationDeactivatedNotification;
NSAccessibilityApplicationHiddenNotification;
NSAccessibilityApplicationShownNotification;

   /* Window notifications
    */
NSAccessibilityWindowCreatedNotification;
NSAccessibilityWindowDeminiaturizedNotification;

   /* Drawer & sheet notifications
    */
NSAccessibilityDrawerCreatedNotification;
NSAccessibilitySheetCreatedNotification;

   /* Misc notifications
    */
NSAccessibilityHelpTagCreatedNotification	;
NSAccessibilityRowCountChangedNotification;

NSAccessibilityRowExpandedNotification	;
NSAccessibilityRowCollapsedNotification	;

   /* Cell-table notifications
    */

   /* Layout area notifications
    */
NSAccessibilityUnitsChangedNotification ;

#endif

   enum { maxNotifications = 6 };
   NSString *notifications[maxNotifications];
   for(unsigned ii = 0; ii < maxNotifications; ++ii)
      notifications[ii] = NULL;

   NSString *& notification = notifications[0];
   NSString *& notification2 = notifications[1];

   switch (eventType)
   {
      case wxACC_EVENT_SYSTEM_MOVESIZEEND:
         notification = NSAccessibilityWindowResizedNotification;
         break;

      case wxACC_EVENT_SYSTEM_MINIMIZEEND:
         notification = NSAccessibilityWindowMiniaturizedNotification;
         break;

      case wxACC_EVENT_OBJECT_CREATE:
         notification = NSAccessibilityCreatedNotification;
         break;

      case wxACC_EVENT_OBJECT_DESTROY:
         notification = NSAccessibilityUIElementDestroyedNotification;
         break;

      case wxACC_EVENT_OBJECT_NAMECHANGE:
         notification = NSAccessibilityTitleChangedNotification;
         break;

      case wxACC_EVENT_OBJECT_VALUECHANGE:
         notification = NSAccessibilityValueChangedNotification;
         break;

      case wxACC_EVENT_OBJECT_LOCATIONCHANGE:
         notification = NSAccessibilityMovedNotification;
         notification2 = NSAccessibilityResizedNotification;
         break;

      case wxACC_EVENT_SYSTEM_DRAGDROPEND:
         // Not sure if this is right...
         if (objectType == wxOBJID_WINDOW)
            notification = NSAccessibilityWindowMovedNotification;
         else
            notification = NSAccessibilityMovedNotification;
         break;

      case wxACC_EVENT_OBJECT_FOCUS:
         // Not sure if this is right...
         if (objectType == wxOBJID_WINDOW)
            notification = NSAccessibilityFocusedWindowChangedNotification;
         else
            notification = NSAccessibilityFocusedUIElementChangedNotification;
         break;

         // Selection notifications... quite a mismatch between the
         // wxWidgets interface and the NS interface.  Just make lots
         // of notifications to cover the possibilities.
      case wxACC_EVENT_OBJECT_SELECTION:
      case wxACC_EVENT_OBJECT_SELECTIONADD:
      case wxACC_EVENT_OBJECT_SELECTIONREMOVE:
      case wxACC_EVENT_OBJECT_SELECTIONWITHIN:
         notifications[0] = NSAccessibilitySelectedTextChangedNotification;
         notifications[1] = NSAccessibilitySelectedChildrenChangedNotification;
         notifications[2] = NSAccessibilitySelectedRowsChangedNotification;
         notifications[3] = NSAccessibilitySelectedColumnsChangedNotification;
         notifications[4] = NSAccessibilitySelectedCellsChangedNotification;
         // notifications[5] = NSAccessibilitySelectedChildrenMovedNotification;
         break;

      case wxACC_EVENT_OBJECT_REORDER:
      case wxACC_EVENT_SYSTEM_SCROLLINGEND:
         notification = NSAccessibilitySelectedChildrenMovedNotification;
         // maybe?
         break;

      case wxACC_EVENT_OBJECT_STATECHANGE:
      case wxACC_EVENT_OBJECT_DESCRIPTIONCHANGE:
      case wxACC_EVENT_OBJECT_PARENTCHANGE:
      case wxACC_EVENT_OBJECT_HELPCHANGE:
      case wxACC_EVENT_OBJECT_DEFACTIONCHANGE:
      case wxACC_EVENT_OBJECT_ACCELERATORCHANGE:
         if (objectType == wxOBJID_CLIENT)
         {
            notification = NSAccessibilitySelectedChildrenChangedNotification;
            // maybe?
            break;
         }
         else
            return;

      case wxACC_EVENT_SYSTEM_SOUND:
      case wxACC_EVENT_SYSTEM_ALERT:
      case wxACC_EVENT_SYSTEM_FOREGROUND:
      case wxACC_EVENT_SYSTEM_MENUSTART:
      case wxACC_EVENT_SYSTEM_MENUEND:
      case wxACC_EVENT_SYSTEM_MENUPOPUPSTART:
      case wxACC_EVENT_SYSTEM_MENUPOPUPEND:
      case wxACC_EVENT_SYSTEM_CAPTURESTART:
      case wxACC_EVENT_SYSTEM_CAPTUREEND:
      case wxACC_EVENT_SYSTEM_MOVESIZESTART:

      case wxACC_EVENT_SYSTEM_CONTEXTHELPSTART:
      case wxACC_EVENT_SYSTEM_CONTEXTHELPEND:
      case wxACC_EVENT_SYSTEM_DRAGDROPSTART:

      case wxACC_EVENT_SYSTEM_DIALOGSTART:
      case wxACC_EVENT_SYSTEM_DIALOGEND:
      case wxACC_EVENT_SYSTEM_SCROLLINGSTART:

      case wxACC_EVENT_SYSTEM_SWITCHSTART:
      case wxACC_EVENT_SYSTEM_SWITCHEND:
      case wxACC_EVENT_SYSTEM_MINIMIZESTART:

      case wxACC_EVENT_OBJECT_SHOW:
      case wxACC_EVENT_OBJECT_HIDE:

      default:
         // no equivalents
      return;
   }

   id element = nil;
   if (objectType == wxOBJID_CLIENT)
   {
      wxAccessible *pAccessible = window->GetAccessible();
      if (!pAccessible)
         return;

      wxAccessible *child = NULL;
      wxAccStatus status = pAccessible->GetChild(objectId, &child);
      element = GetUIElement(*pAccessible, objectId, child);
   }
   else
      element = window->GetPeer()->GetWXWidget();

   if (!element)
      return;

   for(unsigned ii = 0; ii < maxNotifications; ++ii)
   {
      NSString *notification = notifications[ii];
      if (!notification)
         break;
      NSAccessibilityPostNotification(element, notification);
   }
}

void wxOSXCocoaClassAddWXMethods(Class c)
{

#if OBJC_API_VERSION < 2
    static objc_method wxmethods[] =
    {
#endif

    wxOSX_CLASS_ADD_METHOD(c, @selector(stringValue), (IMP) wxOSX_stringValue, "@@:");

    wxOSX_CLASS_ADD_METHOD(c, @selector(mouseDown:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(rightMouseDown:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(otherMouseDown:), (IMP) wxOSX_mouseEvent, "v@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(mouseUp:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(rightMouseUp:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(otherMouseUp:), (IMP) wxOSX_mouseEvent, "v@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(mouseMoved:), (IMP) wxOSX_mouseEvent, "v@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(mouseDragged:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(rightMouseDragged:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(otherMouseDragged:), (IMP) wxOSX_mouseEvent, "v@:@" )
    
    wxOSX_CLASS_ADD_METHOD(c, @selector(acceptsFirstMouse:), (IMP) wxOSX_acceptsFirstMouse, "v@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(scrollWheel:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(mouseEntered:), (IMP) wxOSX_mouseEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(mouseExited:), (IMP) wxOSX_mouseEvent, "v@:@" )
        
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
    wxOSX_CLASS_ADD_METHOD(c, @selector(magnifyWithEvent:), (IMP)wxOSX_mouseEvent, "v@:@")
#endif

    wxOSX_CLASS_ADD_METHOD(c, @selector(cursorUpdate:), (IMP) wxOSX_cursorUpdate, "v@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(keyDown:), (IMP) wxOSX_keyEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(keyUp:), (IMP) wxOSX_keyEvent, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(flagsChanged:), (IMP) wxOSX_keyEvent, "v@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(insertText:), (IMP) wxOSX_insertText, "v@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(performKeyEquivalent:), (IMP) wxOSX_performKeyEquivalent, "c@:@" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(acceptsFirstResponder), (IMP) wxOSX_acceptsFirstResponder, "c@:" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(becomeFirstResponder), (IMP) wxOSX_becomeFirstResponder, "c@:" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(resignFirstResponder), (IMP) wxOSX_resignFirstResponder, "c@:" )

#if !wxOSX_USE_NATIVE_FLIPPED
    wxOSX_CLASS_ADD_METHOD(c, @selector(isFlipped), (IMP) wxOSX_isFlipped, "c@:" )
#endif
    wxOSX_CLASS_ADD_METHOD(c, @selector(drawRect:), (IMP) wxOSX_drawRect, "v@:{_NSRect={_NSPoint=ff}{_NSSize=ff}}" )

    wxOSX_CLASS_ADD_METHOD(c, @selector(controlAction:), (IMP) wxOSX_controlAction, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(controlDoubleAction:), (IMP) wxOSX_controlDoubleAction, "v@:@" )

#if wxUSE_DRAG_AND_DROP
    wxOSX_CLASS_ADD_METHOD(c, @selector(draggingEntered:), (IMP) wxOSX_draggingEntered, "I@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(draggingUpdated:), (IMP) wxOSX_draggingUpdated, "I@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(draggingExited:), (IMP) wxOSX_draggingExited, "v@:@" )
    wxOSX_CLASS_ADD_METHOD(c, @selector(performDragOperation:), (IMP) wxOSX_performDragOperation, "c@:@" )
#endif

    wxOSXCocoaClassAddWXAccessibilityMethods(c);

#if OBJC_API_VERSION < 2
    } ;
    static int method_count = WXSIZEOF( wxmethods );
    static objc_method_list *wxmethodlist = NULL;
    if ( wxmethodlist == NULL )
    {
        wxmethodlist = (objc_method_list*) malloc(sizeof(objc_method_list) + sizeof(wxmethods) );
        memcpy( &wxmethodlist->method_list[0], &wxmethods[0], sizeof(wxmethods) );
        wxmethodlist->method_count = method_count;
        wxmethodlist->obsolete = 0;
    }
    class_addMethods( c, wxmethodlist );
#endif
}

//
// C++ implementation class
//

IMPLEMENT_DYNAMIC_CLASS( wxWidgetCocoaImpl , wxWidgetImpl )

wxWidgetCocoaImpl::wxWidgetCocoaImpl( wxWindowMac* peer , WXWidget w, bool isRootControl, bool isUserPane ) :
    wxWidgetImpl( peer, isRootControl, isUserPane )
{
    Init();
    m_osxView = w;

    // check if the user wants to create the control initially hidden
    if ( !peer->IsShown() )
        SetVisibility(false);

    // gc aware handling
    if ( m_osxView )
        CFRetain(m_osxView);
    [m_osxView release];
}

wxWidgetCocoaImpl::wxWidgetCocoaImpl()
{
    Init();
}

void wxWidgetCocoaImpl::Init()
{
    m_osxView = NULL;
#if !wxOSX_USE_NATIVE_FLIPPED
    m_isFlipped = true;
#endif
    m_lastKeyDownEvent = NULL;
    m_hasEditor = false;
}

wxWidgetCocoaImpl::~wxWidgetCocoaImpl()
{
    if ( GetWXPeer() && GetWXPeer()->IsFrozen() )
        [[m_osxView window] enableFlushWindow];
    
    RemoveAssociations( this );

    if ( !IsRootControl() )
    {
        NSView *sv = [m_osxView superview];
        if ( sv != nil )
            [m_osxView removeFromSuperview];
    }
    // gc aware handling
    if ( m_osxView )
        CFRelease(m_osxView);
}

bool wxWidgetCocoaImpl::IsVisible() const
{
    return [m_osxView isHiddenOrHasHiddenAncestor] == NO;
}

void wxWidgetCocoaImpl::SetVisibility( bool visible )
{
    [m_osxView setHidden:(visible ? NO:YES)];
}

double wxWidgetCocoaImpl::GetContentScaleFactor() const
{
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7
    NSWindow* tlw = [m_osxView window];
    if ( [ tlw respondsToSelector:@selector(backingScaleFactor) ] )
        return [tlw backingScaleFactor];
    else
#endif
        return 1.0;
}

// ----------------------------------------------------------------------------
// window animation stuff
// ----------------------------------------------------------------------------

// define a delegate used to refresh the window during animation
@interface wxNSAnimationDelegate : NSObject wxOSX_10_6_AND_LATER(<NSAnimationDelegate>)
{
    wxWindow *m_win;
    bool m_isDone;
}

- (id)init:(wxWindow *)win;

- (bool)isDone;

// NSAnimationDelegate methods
- (void)animationDidEnd:(NSAnimation*)animation;
- (void)animation:(NSAnimation*)animation
        didReachProgressMark:(NSAnimationProgress)progress;
@end

@implementation wxNSAnimationDelegate

- (id)init:(wxWindow *)win
{
    self = [super init];

    m_win = win;
    m_isDone = false;

    return self;
}

- (bool)isDone
{
    return m_isDone;
}

- (void)animation:(NSAnimation*)animation
        didReachProgressMark:(NSAnimationProgress)progress
{
    wxUnusedVar(animation);
    wxUnusedVar(progress);

    m_win->SendSizeEvent();
}

- (void)animationDidEnd:(NSAnimation*)animation
{
    wxUnusedVar(animation);
    m_isDone = true;
}

@end

/* static */
bool
wxWidgetCocoaImpl::ShowViewOrWindowWithEffect(wxWindow *win,
                                              bool show,
                                              wxShowEffect effect,
                                              unsigned timeout)
{
    // create the dictionary describing the animation to perform on this view
    NSObject * const
        viewOrWin = static_cast<NSObject *>(win->OSXGetViewOrWindow());
    NSMutableDictionary * const
        dict = [NSMutableDictionary dictionaryWithCapacity:4];
    [dict setObject:viewOrWin forKey:NSViewAnimationTargetKey];

    // determine the start and end rectangles assuming we're hiding the window
    const wxRect rectOrig = win->GetRect();
    wxRect rectStart,
           rectEnd;
    rectStart =
    rectEnd = rectOrig;

    if ( show )
    {
        if ( effect == wxSHOW_EFFECT_ROLL_TO_LEFT ||
                effect == wxSHOW_EFFECT_SLIDE_TO_LEFT )
            effect = wxSHOW_EFFECT_ROLL_TO_RIGHT;
        else if ( effect == wxSHOW_EFFECT_ROLL_TO_RIGHT ||
                    effect == wxSHOW_EFFECT_SLIDE_TO_RIGHT )
            effect = wxSHOW_EFFECT_ROLL_TO_LEFT;
        else if ( effect == wxSHOW_EFFECT_ROLL_TO_TOP ||
                    effect == wxSHOW_EFFECT_SLIDE_TO_TOP )
            effect = wxSHOW_EFFECT_ROLL_TO_BOTTOM;
        else if ( effect == wxSHOW_EFFECT_ROLL_TO_BOTTOM ||
                    effect == wxSHOW_EFFECT_SLIDE_TO_BOTTOM )
            effect = wxSHOW_EFFECT_ROLL_TO_TOP;
    }

    switch ( effect )
    {
        case wxSHOW_EFFECT_ROLL_TO_LEFT:
        case wxSHOW_EFFECT_SLIDE_TO_LEFT:
            rectEnd.width = 0;
            break;

        case wxSHOW_EFFECT_ROLL_TO_RIGHT:
        case wxSHOW_EFFECT_SLIDE_TO_RIGHT:
            rectEnd.x = rectStart.GetRight();
            rectEnd.width = 0;
            break;

        case wxSHOW_EFFECT_ROLL_TO_TOP:
        case wxSHOW_EFFECT_SLIDE_TO_TOP:
            rectEnd.height = 0;
            break;

        case wxSHOW_EFFECT_ROLL_TO_BOTTOM:
        case wxSHOW_EFFECT_SLIDE_TO_BOTTOM:
            rectEnd.y = rectStart.GetBottom();
            rectEnd.height = 0;
            break;

        case wxSHOW_EFFECT_EXPAND:
            rectEnd.x = rectStart.x + rectStart.width / 2;
            rectEnd.y = rectStart.y + rectStart.height / 2;
            rectEnd.width =
            rectEnd.height = 0;
            break;

        case wxSHOW_EFFECT_BLEND:
            [dict setObject:(show ? NSViewAnimationFadeInEffect
                                  : NSViewAnimationFadeOutEffect)
                  forKey:NSViewAnimationEffectKey];
            break;

        case wxSHOW_EFFECT_NONE:
        case wxSHOW_EFFECT_MAX:
            wxFAIL_MSG( "unexpected animation effect" );
            return false;

        default:
            wxFAIL_MSG( "unknown animation effect" );
            return false;
    };

    if ( show )
    {
        // we need to restore it to the original rectangle instead of making it
        // disappear
        wxSwap(rectStart, rectEnd);

        // and as the window is currently hidden, we need to show it for the
        // animation to be visible at all (but don't restore it at its full
        // rectangle as it shouldn't appear immediately)
        win->SetSize(rectStart);
        win->Show();
    }

    NSView * const parentView = [viewOrWin isKindOfClass:[NSView class]]
                                    ? [(NSView *)viewOrWin superview]
                                    : nil;
    const NSRect rStart = wxToNSRect(parentView, rectStart);
    const NSRect rEnd = wxToNSRect(parentView, rectEnd);

    [dict setObject:[NSValue valueWithRect:rStart]
          forKey:NSViewAnimationStartFrameKey];
    [dict setObject:[NSValue valueWithRect:rEnd]
          forKey:NSViewAnimationEndFrameKey];

    // create an animation using the values in the above dictionary
    NSViewAnimation * const
        anim = [[NSViewAnimation alloc]
                initWithViewAnimations:[NSArray arrayWithObject:dict]];

    if ( !timeout )
    {
        // what is a good default duration? Windows uses 200ms, Web frameworks
        // use anything from 250ms to 1s... choose something in the middle
        timeout = 500;
    }

    [anim setDuration:timeout/1000.];   // duration is in seconds here

    // if the window being animated changes its layout depending on its size
    // (which is almost always the case) we need to redo it during animation
    //
    // the number of layouts here is arbitrary, but 10 seems like too few (e.g.
    // controls in wxInfoBar visibly jump around)
    const int NUM_LAYOUTS = 20;
    for ( float f = 1./NUM_LAYOUTS; f < 1.; f += 1./NUM_LAYOUTS )
        [anim addProgressMark:f];

    wxNSAnimationDelegate * const
        animDelegate = [[wxNSAnimationDelegate alloc] init:win];
    [anim setDelegate:animDelegate];
    [anim startAnimation];

    // Cocoa is capable of doing animation asynchronously or even from separate
    // thread but wx API doesn't provide any way to be notified about the
    // animation end and without this we really must ensure that the window has
    // the expected (i.e. the same as if a simple Show() had been used) size
    // when we return, so block here until the animation finishes
    //
    // notice that because the default animation mode is NSAnimationBlocking,
    // no user input events ought to be processed from here
    {
        wxEventLoopGuarantor ensureEventLoopExistence;
        wxEventLoopBase * const loop = wxEventLoopBase::GetActive();
        while ( ![animDelegate isDone] )
            loop->Dispatch();
    }

    if ( !show )
    {
        // NSViewAnimation is smart enough to hide the NSView being animated at
        // the end but we also must ensure that it's hidden for wx too
        win->Hide();

        // and we must also restore its size because it isn't expected to
        // change just because the window was hidden
        win->SetSize(rectOrig);
    }
    else
    {
        // refresh it once again after the end to ensure that everything is in
        // place
        win->SendSizeEvent();
    }

    [anim setDelegate:nil];
    [animDelegate release];
    [anim release];

    return true;
}

bool wxWidgetCocoaImpl::ShowWithEffect(bool show,
                                       wxShowEffect effect,
                                       unsigned timeout)
{
    return ShowViewOrWindowWithEffect(m_wxPeer, show, effect, timeout);
}

/* note that the drawing order between siblings is not defined under 10.4 */
/* only starting from 10.5 the subview order is respected */

/* NSComparisonResult is typedef'd as an enum pre-Leopard but typedef'd as
 * NSInteger post-Leopard.  Pre-Leopard the Cocoa toolkit expects a function
 * returning int and not NSComparisonResult.  Post-Leopard the Cocoa toolkit
 * expects a function returning the new non-enum NSComparsionResult.
 * Hence we create a typedef named CocoaWindowCompareFunctionResult.
 */
#if defined(NSINTEGER_DEFINED)
typedef NSComparisonResult CocoaWindowCompareFunctionResult;
#else
typedef int CocoaWindowCompareFunctionResult;
#endif

class CocoaWindowCompareContext
{
    wxDECLARE_NO_COPY_CLASS(CocoaWindowCompareContext);
public:
    CocoaWindowCompareContext(); // Not implemented
    CocoaWindowCompareContext(NSView *target, NSArray *subviews)
    {
        m_target = target;
        // Cocoa sorts subviews in-place.. make a copy
        m_subviews = [subviews copy];
    }
    
    ~CocoaWindowCompareContext()
    {   // release the copy
        [m_subviews release];
    }
    NSView* target()
    {   return m_target; }
    
    NSArray* subviews()
    {   return m_subviews; }
    
    /* Helper function that returns the comparison based off of the original ordering */
    CocoaWindowCompareFunctionResult CompareUsingOriginalOrdering(id first, id second)
    {
        NSUInteger firstI = [m_subviews indexOfObjectIdenticalTo:first];
        NSUInteger secondI = [m_subviews indexOfObjectIdenticalTo:second];
        // NOTE: If either firstI or secondI is NSNotFound then it will be NSIntegerMax and thus will
        // likely compare higher than the other view which is reasonable considering the only way that
        // can happen is if the subview was added after our call to subviews but before the call to
        // sortSubviewsUsingFunction:context:.  Thus we don't bother checking.  Particularly because
        // that case should never occur anyway because that would imply a multi-threaded GUI call
        // which is a big no-no with Cocoa.
		
        // Subviews are ordered from back to front meaning one that is already lower will have an lower index.
        NSComparisonResult result = (firstI < secondI)
		?   NSOrderedAscending /* -1 */
		:   (firstI > secondI)
		?   NSOrderedDescending /* 1 */
		:   NSOrderedSame /* 0 */;
		
        return result;
    }
private:
    /* The subview we are trying to Raise or Lower */
    NSView *m_target;
    /* A copy of the original array of subviews */
    NSArray *m_subviews;
};

/* Causes Cocoa to raise the target view to the top of the Z-Order by telling the sort function that
 * the target view is always higher than every other view.  When comparing two views neither of
 * which is the target, it returns the correct response based on the original ordering
 */
static CocoaWindowCompareFunctionResult CocoaRaiseWindowCompareFunction(id first, id second, void *ctx)
{
    CocoaWindowCompareContext *compareContext = (CocoaWindowCompareContext*)ctx;
    // first should be ordered higher
    if(first==compareContext->target())
        return NSOrderedDescending;
    // second should be ordered higher
    if(second==compareContext->target())
        return NSOrderedAscending;
    return compareContext->CompareUsingOriginalOrdering(first,second);
}

void wxWidgetCocoaImpl::Raise()
{
	NSView* nsview = m_osxView;
	
    NSView *superview = [nsview superview];
    CocoaWindowCompareContext compareContext(nsview, [superview subviews]);
	
    [superview sortSubviewsUsingFunction:
	 CocoaRaiseWindowCompareFunction
								 context: &compareContext];
	
}

/* Causes Cocoa to lower the target view to the bottom of the Z-Order by telling the sort function that
 * the target view is always lower than every other view.  When comparing two views neither of
 * which is the target, it returns the correct response based on the original ordering
 */
static CocoaWindowCompareFunctionResult CocoaLowerWindowCompareFunction(id first, id second, void *ctx)
{
    CocoaWindowCompareContext *compareContext = (CocoaWindowCompareContext*)ctx;
    // first should be ordered lower
    if(first==compareContext->target())
        return NSOrderedAscending;
    // second should be ordered lower
    if(second==compareContext->target())
        return NSOrderedDescending;
    return compareContext->CompareUsingOriginalOrdering(first,second);
}

void wxWidgetCocoaImpl::Lower()
{
	NSView* nsview = m_osxView;
	
    NSView *superview = [nsview superview];
    CocoaWindowCompareContext compareContext(nsview, [superview subviews]);
	
    [superview sortSubviewsUsingFunction:
	 CocoaLowerWindowCompareFunction
								 context: &compareContext];
}

void wxWidgetCocoaImpl::ScrollRect( const wxRect *WXUNUSED(rect), int WXUNUSED(dx), int WXUNUSED(dy) )
{
#if 1
    SetNeedsDisplay() ;
#else
    // We should do something like this, but it wasn't working in 10.4.
    if (GetNeedsDisplay() )
    {
        SetNeedsDisplay() ;
    }
    NSRect r = wxToNSRect( [m_osxView superview], *rect );
    NSSize offset = NSMakeSize((float)dx, (float)dy);
    [m_osxView scrollRect:r by:offset];
#endif
}

void wxWidgetCocoaImpl::Move(int x, int y, int width, int height)
{
    wxWindowMac* parent = GetWXPeer()->GetParent();
    // under Cocoa we might have a contentView in the wxParent to which we have to
    // adjust the coordinates
    if (parent && [m_osxView superview] != parent->GetHandle() )
    {
        int cx = 0,cy = 0,cw = 0,ch = 0;
        if ( parent->GetPeer() )
        {
            parent->GetPeer()->GetContentArea(cx, cy, cw, ch);
            x -= cx;
            y -= cy;
        }
    }
    [[m_osxView superview] setNeedsDisplayInRect:[m_osxView frame]];
    NSRect r = wxToNSRect( [m_osxView superview], wxRect(x,y,width, height) );
    [m_osxView setFrame:r];
    [[m_osxView superview] setNeedsDisplayInRect:r];
}

void wxWidgetCocoaImpl::GetPosition( int &x, int &y ) const
{
    wxRect r = wxFromNSRect( [m_osxView superview], [m_osxView frame] );
    x = r.GetLeft();
    y = r.GetTop();
    
    // under Cocoa we might have a contentView in the wxParent to which we have to
    // adjust the coordinates
    wxWindowMac* parent = GetWXPeer()->GetParent();
    if (parent && [m_osxView superview] != parent->GetHandle() )
    {
        int cx = 0,cy = 0,cw = 0,ch = 0;
        if ( parent->GetPeer() )
        {
            parent->GetPeer()->GetContentArea(cx, cy, cw, ch);
            x += cx;
            y += cy;
        }
    }
}

void wxWidgetCocoaImpl::GetSize( int &width, int &height ) const
{
    NSRect rect = [m_osxView frame];
    width = (int)rect.size.width;
    height = (int)rect.size.height;
}

void wxWidgetCocoaImpl::GetContentArea( int&left, int &top, int &width, int &height ) const
{
    if ( [m_osxView respondsToSelector:@selector(contentView) ] )
    {
        NSView* cv = [m_osxView contentView];

        NSRect bounds = [m_osxView bounds];
        NSRect rect = [cv frame];

        int y = (int)rect.origin.y;
        int x = (int)rect.origin.x;
        if ( ![ m_osxView isFlipped ] )
            y = (int)(bounds.size.height - (rect.origin.y + rect.size.height));
        left = x;
        top = y;
        width = (int)rect.size.width;
        height = (int)rect.size.height;
    }
    else
    {
        left = top = 0;
        GetSize( width, height );
    }
}

void wxWidgetCocoaImpl::SetNeedsDisplay( const wxRect* where )
{
    if ( where )
        [m_osxView setNeedsDisplayInRect:wxToNSRect(m_osxView, *where )];
    else
        [m_osxView setNeedsDisplay:YES];
}

bool wxWidgetCocoaImpl::GetNeedsDisplay() const
{
    return [m_osxView needsDisplay];
}

bool wxWidgetCocoaImpl::CanFocus() const
{
    return [m_osxView canBecomeKeyView] == YES;
}

bool wxWidgetCocoaImpl::HasFocus() const
{
    return ( FindFocus() == m_osxView );
}

bool wxWidgetCocoaImpl::SetFocus()
{
    if ( !CanFocus() )
        return false;

    // TODO remove if no issues arise: should not raise the window, only assign focus
    //[[m_osxView window] makeKeyAndOrderFront:nil] ;
    [[m_osxView window] makeFirstResponder: m_osxView] ;
    return true;
}

#if wxUSE_DRAG_AND_DROP
void wxWidgetCocoaImpl::SetDropTarget(wxDropTarget* target)
{
    [m_osxView unregisterDraggedTypes];
    
    if ( target == NULL )
        return;
    
    wxDataObject* dobj = target->GetDataObject();
    
    if( dobj )
    {
        CFMutableArrayRef typesarray = CFArrayCreateMutable(kCFAllocatorDefault,0,&kCFTypeArrayCallBacks);
        dobj->AddSupportedTypes(typesarray);
        NSView* targetView = m_osxView;
        if ( [m_osxView isKindOfClass:[NSScrollView class] ] )
            targetView = [(NSScrollView*) m_osxView documentView];

        [targetView registerForDraggedTypes:(NSArray*)typesarray];
        CFRelease(typesarray);
    }
}
#endif // wxUSE_DRAG_AND_DROP

void wxWidgetCocoaImpl::RemoveFromParent()
{
    [m_osxView removeFromSuperview];
}

void wxWidgetCocoaImpl::Embed( wxWidgetImpl *parent )
{
    NSView* container = parent->GetWXWidget() ;
    wxASSERT_MSG( container != NULL , wxT("No valid mac container control") ) ;
    [container addSubview:m_osxView];
    
    if( m_wxPeer->IsFrozen() )
        [[m_osxView window] disableFlushWindow];
}

void wxWidgetCocoaImpl::SetBackgroundColour( const wxColour &col )
{
    NSView* targetView = m_osxView;
    if ( [m_osxView isKindOfClass:[NSScrollView class] ] )
        targetView = [(NSScrollView*) m_osxView documentView];

    if ( [targetView respondsToSelector:@selector(setBackgroundColor:) ] )
    {
        [targetView setBackgroundColor:[NSColor colorWithCalibratedRed:(CGFloat) (col.Red() / 255.0)
                                                                green:(CGFloat) (col.Green() / 255.0)
                                                                 blue:(CGFloat) (col.Blue() / 255.0)
                                                                alpha:(CGFloat) (col.Alpha() / 255.0)]];
    }
}

bool wxWidgetCocoaImpl::SetBackgroundStyle( wxBackgroundStyle style )
{
    BOOL opaque = ( style == wxBG_STYLE_PAINT );
    
    if ( [m_osxView respondsToSelector:@selector(setOpaque:) ] )
    {
        [m_osxView setOpaque: opaque];
    }
    
    return true ;
}

void wxWidgetCocoaImpl::SetLabel( const wxString& title, wxFontEncoding encoding )
{
    if ( [m_osxView respondsToSelector:@selector(setTitle:) ] )
    {
        wxCFStringRef cf( title , encoding );
        [m_osxView setTitle:cf.AsNSString()];
    }
    else if ( [m_osxView respondsToSelector:@selector(setStringValue:) ] )
    {
        wxCFStringRef cf( title , encoding );
        [m_osxView setStringValue:cf.AsNSString()];
    }
}


void  wxWidgetImpl::Convert( wxPoint *pt , wxWidgetImpl *from , wxWidgetImpl *to )
{
    NSPoint p = wxToNSPoint( from->GetWXWidget(), *pt );
    p = [from->GetWXWidget() convertPoint:p toView:to->GetWXWidget() ];
    *pt = wxFromNSPoint( to->GetWXWidget(), p );
}

wxInt32 wxWidgetCocoaImpl::GetValue() const
{
    return [(NSControl*)m_osxView intValue];
}

void wxWidgetCocoaImpl::SetValue( wxInt32 v )
{
    if (  [m_osxView respondsToSelector:@selector(setIntValue:)] )
    {
        [m_osxView setIntValue:v];
    }
    else if (  [m_osxView respondsToSelector:@selector(setFloatValue:)] )
    {
        [m_osxView setFloatValue:(double)v];
    }
    else if (  [m_osxView respondsToSelector:@selector(setDoubleValue:)] )
    {
        [m_osxView setDoubleValue:(double)v];
    }
}

void wxWidgetCocoaImpl::SetMinimum( wxInt32 v )
{
    if (  [m_osxView respondsToSelector:@selector(setMinValue:)] )
    {
        [m_osxView setMinValue:(double)v];
    }
}

void wxWidgetCocoaImpl::SetMaximum( wxInt32 v )
{
    if (  [m_osxView respondsToSelector:@selector(setMaxValue:)] )
    {
        [m_osxView setMaxValue:(double)v];
    }
}

wxInt32 wxWidgetCocoaImpl::GetMinimum() const
{
    if (  [m_osxView respondsToSelector:@selector(minValue)] )
    {
        return (int)[m_osxView minValue];
    }
    return 0;
}

wxInt32 wxWidgetCocoaImpl::GetMaximum() const
{
    if (  [m_osxView respondsToSelector:@selector(maxValue)] )
    {
        return (int)[m_osxView maxValue];
    }
    return 0;
}

wxBitmap wxWidgetCocoaImpl::GetBitmap() const
{
    wxBitmap bmp;

    // TODO: how to create a wxBitmap from NSImage?
#if 0
    if ( [m_osxView respondsToSelector:@selector(image:)] )
        bmp = [m_osxView image];
#endif

    return bmp;
}

void wxWidgetCocoaImpl::SetBitmap( const wxBitmap& bitmap )
{
    if (  [m_osxView respondsToSelector:@selector(setImage:)] )
    {
        if (bitmap.IsOk())
            [m_osxView setImage:bitmap.GetNSImage()];
        else
            [m_osxView setImage:nil];

        [m_osxView setNeedsDisplay:YES];
    }
}

void wxWidgetCocoaImpl::SetBitmapPosition( wxDirection dir )
{
    if ( [m_osxView respondsToSelector:@selector(setImagePosition:)] )
    {
        NSCellImagePosition pos;
        switch ( dir )
        {
            case wxLEFT:
                pos = NSImageLeft;
                break;

            case wxRIGHT:
                pos = NSImageRight;
                break;

            case wxTOP:
                pos = NSImageAbove;
                break;

            case wxBOTTOM:
                pos = NSImageBelow;
                break;

            default:
                wxFAIL_MSG( "invalid image position" );
                pos = NSNoImage;
        }

        [m_osxView setImagePosition:pos];
    }
}

void wxWidgetCocoaImpl::SetupTabs( const wxNotebook& WXUNUSED(notebook))
{
    // implementation in subclass
}

void wxWidgetCocoaImpl::GetBestRect( wxRect *r ) const
{
    r->x = r->y = r->width = r->height = 0;

    if (  [m_osxView respondsToSelector:@selector(sizeToFit)] )
    {
        NSRect former = [m_osxView frame];
        [m_osxView sizeToFit];
        NSRect best = [m_osxView frame];
        [m_osxView setFrame:former];
        r->width = (int)best.size.width;
        r->height = (int)best.size.height;
    }
}

bool wxWidgetCocoaImpl::IsEnabled() const
{
    NSView* targetView = m_osxView;
    if ( [m_osxView isKindOfClass:[NSScrollView class] ] )
        targetView = [(NSScrollView*) m_osxView documentView];

    if ( [targetView respondsToSelector:@selector(isEnabled) ] )
        return [targetView isEnabled];
    return true;
}

void wxWidgetCocoaImpl::Enable( bool enable )
{
    NSView* targetView = m_osxView;
    if ( [m_osxView isKindOfClass:[NSScrollView class] ] )
        targetView = [(NSScrollView*) m_osxView documentView];

    if ( [targetView respondsToSelector:@selector(setEnabled:) ] )
        [targetView setEnabled:enable];
}

void wxWidgetCocoaImpl::PulseGauge()
{
}

void wxWidgetCocoaImpl::SetScrollThumb( wxInt32 WXUNUSED(val), wxInt32 WXUNUSED(view) )
{
}

void wxWidgetCocoaImpl::SetControlSize( wxWindowVariant variant )
{
    NSControlSize size = NSRegularControlSize;

    switch ( variant )
    {
        case wxWINDOW_VARIANT_NORMAL :
            size = NSRegularControlSize;
            break ;

        case wxWINDOW_VARIANT_SMALL :
            size = NSSmallControlSize;
            break ;

        case wxWINDOW_VARIANT_MINI :
            size = NSMiniControlSize;
            break ;

        case wxWINDOW_VARIANT_LARGE :
            size = NSRegularControlSize;
            break ;

        default:
            wxFAIL_MSG(wxT("unexpected window variant"));
            break ;
    }
    if ( [m_osxView respondsToSelector:@selector(setControlSize:)] )
        [m_osxView setControlSize:size];
    else if ([m_osxView respondsToSelector:@selector(cell)])
    {
        id cell = [(id)m_osxView cell];
        if ([cell respondsToSelector:@selector(setControlSize:)])
            [cell setControlSize:size];
    }

    // we need to propagate this to inner views as well
    if ( [m_osxView isKindOfClass:[NSScrollView class] ] )
    {
        NSView* targetView = [(NSScrollView*) m_osxView documentView];
    
        if ( [targetView respondsToSelector:@selector(setControlSize:)] )
            [targetView setControlSize:size];
        else if ([targetView respondsToSelector:@selector(cell)])
        {
            id cell = [(id)targetView cell];
            if ([cell respondsToSelector:@selector(setControlSize:)])
                [cell setControlSize:size];
        }
    }
}

void wxWidgetCocoaImpl::SetFont(wxFont const& font, wxColour const&col, long, bool)
{
    NSView* targetView = m_osxView;
    if ( [m_osxView isKindOfClass:[NSScrollView class] ] )
        targetView = [(NSScrollView*) m_osxView documentView];

    if ([targetView respondsToSelector:@selector(setFont:)])
        [targetView setFont: font.OSXGetNSFont()];
    if ([targetView respondsToSelector:@selector(setTextColor:)])
        [targetView setTextColor:[NSColor colorWithCalibratedRed:(CGFloat) (col.Red() / 255.0)
                                                                 green:(CGFloat) (col.Green() / 255.0)
                                                                  blue:(CGFloat) (col.Blue() / 255.0)
                                                                 alpha:(CGFloat) (col.Alpha() / 255.0)]];
}

void wxWidgetCocoaImpl::SetToolTip(wxToolTip* tooltip)
{
    if ( tooltip )
    {
        wxCFStringRef cf( tooltip->GetTip() , m_wxPeer->GetFont().GetEncoding() );
        [m_osxView setToolTip: cf.AsNSString()];
    }
    else 
    {
        [m_osxView setToolTip:nil];
    }
}

void wxWidgetCocoaImpl::InstallEventHandler( WXWidget control )
{
    WXWidget c =  control ? control : (WXWidget) m_osxView;
    wxWidgetImpl::Associate( c, this ) ;
    if ([c respondsToSelector:@selector(setAction:)])
    {
        [c setTarget: c];
        if ( dynamic_cast<wxRadioButton*>(GetWXPeer()) )
        {
            // everything already set up
        }
        else
            [c setAction: @selector(controlAction:)];
        
        if ([c respondsToSelector:@selector(setDoubleAction:)])
        {
            [c setDoubleAction: @selector(controlDoubleAction:)];
        }

    }
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited|NSTrackingCursorUpdate|NSTrackingMouseMoved|NSTrackingActiveAlways|NSTrackingInVisibleRect;
    NSTrackingArea* area = [[NSTrackingArea alloc] initWithRect: NSZeroRect options: options owner: m_osxView userInfo: nil];
    [m_osxView addTrackingArea: area];
    [area release];
 }

bool wxWidgetCocoaImpl::DoHandleCharEvent(NSEvent *event, NSString *text)
{
    bool result = false;
    
    for (NSUInteger i = 0; i < [text length]; ++i)
    {
        wxKeyEvent wxevent(wxEVT_CHAR);
        unichar c = [text characterAtIndex:i];
        SetupKeyEvent( wxevent, event, [NSString stringWithCharacters:&c length:1]);

        result = GetWXPeer()->OSXHandleKeyEvent(wxevent) || result;
    }
    
    return result;
}

bool wxWidgetCocoaImpl::DoHandleKeyEvent(NSEvent *event)
{
    wxKeyEvent wxevent(wxEVT_KEY_DOWN);
    SetupKeyEvent( wxevent, event );

    // Generate wxEVT_CHAR_HOOK before sending any other events but only when
    // the key is pressed, not when it's released (the type of wxevent is
    // changed by SetupKeyEvent() so it can be wxEVT_KEY_UP too by now).
    if ( wxevent.GetEventType() == wxEVT_KEY_DOWN )
    {
        wxKeyEvent eventHook(wxEVT_CHAR_HOOK, wxevent);
        if ( GetWXPeer()->OSXHandleKeyEvent(eventHook)
                && !eventHook.IsNextEventAllowed() )
            return true;
    }

    if ( IsUserPane() && [event type] == NSKeyDown)
    {
        // Don't fire wxEVT_KEY_DOWN here in order to allow IME to intercept
        // some key events. If the event is not handled by IME, either
        // insertText: or doCommandBySelector: is called, so we send
        // wxEVT_KEY_DOWN and wxEVT_CHAR there.

        if ( [m_osxView isKindOfClass:[NSScrollView class] ] )
            [[(NSScrollView*)m_osxView documentView] interpretKeyEvents:[NSArray arrayWithObject:event]];
        else
            [m_osxView interpretKeyEvents:[NSArray arrayWithObject:event]];
        return true;
    }
    else
    {
        return GetWXPeer()->OSXHandleKeyEvent(wxevent);
    }
}

bool wxWidgetCocoaImpl::DoHandleMouseEvent(NSEvent *event)
{
    wxMouseEvent wxevent(wxEVT_LEFT_DOWN);
    SetupMouseEvent(wxevent , event) ;
    bool result = GetWXPeer()->HandleWindowEvent(wxevent);
    
    (void)SetupCursor(event);

    return result;
}

void wxWidgetCocoaImpl::DoNotifyFocusSet()
{
    NSResponder* responder = wxNonOwnedWindowCocoaImpl::GetFormerFirstResponder();
    NSView* otherView = wxOSXGetViewFromResponder(responder);
    wxWidgetImpl* otherWindow = FindFromWXWidget(otherView);
    
    // It doesn't make sense to notify about the focus set if it's the same
    // control in the end, and just a different subview
    if ( otherWindow != this )
        DoNotifyFocusEvent(true, otherWindow);
}

void wxWidgetCocoaImpl::DoNotifyFocusLost()
{
    NSResponder * responder = wxNonOwnedWindowCocoaImpl::GetNextFirstResponder();
    NSView* otherView = wxOSXGetViewFromResponder(responder);
    wxWidgetImpl* otherWindow = FindBestFromWXWidget(otherView);
    
    // It doesn't make sense to notify about the loss of focus if it's the same
    // control in the end, and just a different subview
    if ( otherWindow != this )
        DoNotifyFocusEvent( false, otherWindow );
}

void wxWidgetCocoaImpl::DoNotifyFocusEvent(bool receivedFocus, wxWidgetImpl* otherWindow)
{
    wxWindow* thisWindow = GetWXPeer();
    if ( thisWindow->MacGetTopLevelWindow() && NeedsFocusRect() )
    {
        thisWindow->MacInvalidateBorders();
    }

    if ( receivedFocus )
    {
        wxLogTrace(wxT("Focus"), wxT("focus set(%p)"), static_cast<void*>(thisWindow));
        wxChildFocusEvent eventFocus((wxWindow*)thisWindow);
        thisWindow->HandleWindowEvent(eventFocus);

#if wxUSE_CARET
        if ( thisWindow->GetCaret() )
            thisWindow->GetCaret()->OnSetFocus();
#endif

        wxFocusEvent event(wxEVT_SET_FOCUS, thisWindow->GetId());
        event.SetEventObject(thisWindow);
        if (otherWindow)
            event.SetWindow(otherWindow->GetWXPeer());
        thisWindow->HandleWindowEvent(event) ;
    }
    else // !receivedFocus
    {
#if wxUSE_CARET
        if ( thisWindow->GetCaret() )
            thisWindow->GetCaret()->OnKillFocus();
#endif

        wxLogTrace(wxT("Focus"), wxT("focus lost(%p)"), static_cast<void*>(thisWindow));

        wxFocusEvent event( wxEVT_KILL_FOCUS, thisWindow->GetId());
        event.SetEventObject(thisWindow);
        if (otherWindow)
            event.SetWindow(otherWindow->GetWXPeer());
        thisWindow->HandleWindowEvent(event) ;
    }
}

void wxWidgetCocoaImpl::SetCursor(const wxCursor& cursor)
{
    if ( !wxIsBusy() )
    {
        NSPoint location = [NSEvent mouseLocation];
        location = [[m_osxView window] convertScreenToBase:location];
        NSPoint locationInView = [m_osxView convertPoint:location fromView:nil];

        if( NSMouseInRect(locationInView, [m_osxView bounds], YES) )
        {
            [(NSCursor*)cursor.GetHCURSOR() set];
        }
    }
}

void wxWidgetCocoaImpl::CaptureMouse()
{
    // TODO remove if we don't get into problems with cursor settings
    //    [[m_osxView window] disableCursorRects];
}

void wxWidgetCocoaImpl::ReleaseMouse()
{
    // TODO remove if we don't get into problems with cursor settings
    //    [[m_osxView window] enableCursorRects];
}

#if !wxOSX_USE_NATIVE_FLIPPED

void wxWidgetCocoaImpl::SetFlipped(bool flipped)
{
    m_isFlipped = flipped;
}

#endif

void wxWidgetCocoaImpl::SetDrawingEnabled(bool enabled)
{
    if ( enabled )
    {
        [[m_osxView window] enableFlushWindow];
        [m_osxView setNeedsDisplay:YES];
    }
    else
    {
        [[m_osxView window] disableFlushWindow];
    }
}
//
// Factory methods
//

wxWidgetImpl* wxWidgetImpl::CreateUserPane( wxWindowMac* wxpeer, wxWindowMac* WXUNUSED(parent),
    wxWindowID WXUNUSED(id), const wxPoint& pos, const wxSize& size,
    long WXUNUSED(style), long WXUNUSED(extraStyle))
{
    NSRect r = wxOSXGetFrameForControl( wxpeer, pos , size ) ;
    wxNSView* v = [[wxNSView alloc] initWithFrame:r];

    wxWidgetCocoaImpl* c = new wxWidgetCocoaImpl( wxpeer, v, false, true );
    return c;
}

wxWidgetImpl* wxWidgetImpl::CreateContentView( wxNonOwnedWindow* now )
{
    NSWindow* tlw = now->GetWXWindow();
    
    wxWidgetCocoaImpl* c = NULL;
    if ( now->IsNativeWindowWrapper() )
    {
        NSView* cv = [tlw contentView];
        c = new wxWidgetCocoaImpl( now, cv, true );
        if ( cv != nil )
        {
            // increase ref count, because the impl destructor will decrement it again
            CFRetain(cv);
            if ( !now->IsShown() )
                [cv setHidden:NO];
        }
    }
    else
    {
        wxNSView* v = [[wxNSView alloc] initWithFrame:[[tlw contentView] frame]];
        c = new wxWidgetCocoaImpl( now, v, true );
        c->InstallEventHandler();
        [tlw setContentView:v];
    }
    return c;
}
