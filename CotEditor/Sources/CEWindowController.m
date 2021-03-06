/*
 ==============================================================================
 CEWindowController
 
 CotEditor
 http://coteditor.com
 
 Created on 2004-12-13 by nakamuxu
 encoding="UTF-8"
 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2015 1024jp
 
 This program is free software; you can redistribute it and/or modify it under
 the terms of the GNU General Public License as published by the Free Software
 Foundation; either version 2 of the License, or (at your option) any later
 version.
 
 This program is distributed in the hope that it will be useful, but WITHOUT
 ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License along with
 this program; if not, write to the Free Software Foundation, Inc., 59 Temple
 Place - Suite 330, Boston, MA  02111-1307, USA.
 
 ==============================================================================
 */

#import "CEWindowController.h"
#import <OgreKit/OgreTextFinder.h>
#import "CEWindow.h"
#import "CEDocument.h"
#import "CEStatusBarController.h"
#import "CEIncompatibleCharsViewController.h"
#import "CEEditorWrapper.h"
#import "CESyntaxManager.h"
#import "CEDocumentAnalyzer.h"
#import "constants.h"


// sidebar mode
typedef NS_ENUM(NSUInteger, CESidebarTag) {
    CEDocumentInspectorTag = 1,
    CEIncompatibleCharsTag,
};


@interface CEWindowController () <OgreTextFindDataSource, NSSplitViewDelegate>

@property (nonatomic) CESidebarTag selectedSidebarTag;
@property (nonatomic) BOOL needsRecolorWithBecomeKey;  // flag to update sytnax highlight when window becomes key window
@property (nonatomic) NSTimer *editorInfoUpdateTimer;
@property (nonatomic) CGFloat sidebarWidth;


// IBOutlets
@property (nonatomic) IBOutlet CEStatusBarController *statusBarController;
@property (nonatomic) IBOutlet NSViewController *documentInspectorViewController;
@property (nonatomic) IBOutlet CEIncompatibleCharsViewController *incompatibleCharsViewController;
@property (nonatomic, weak) IBOutlet NSSplitView *sidebarSplitView;
@property (nonatomic, weak) IBOutlet NSView *sidebar;
@property (nonatomic, weak) IBOutlet NSView *sidebarPlaceholderView;
@property (nonatomic) IBOutlet CEDocumentAnalyzer *documentAnalyzer;

// IBOutlets (readonly)
@property (readwrite, nonatomic, weak) IBOutlet CEToolbarController *toolbarController;
@property (readwrite, nonatomic, weak) IBOutlet CEEditorWrapper *editor;

@end




#pragma mark -

@implementation CEWindowController

static NSTimeInterval infoUpdateInterval;


#pragma mark Superclass Methods

// ------------------------------------------------------
/// initialize class
+ (void)initialize
// ------------------------------------------------------
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        
        infoUpdateInterval = [defaults doubleForKey:CEDefaultInfoUpdateIntervalKey];
    });
}


// ------------------------------------------------------
/// clean up
- (void)dealloc
// ------------------------------------------------------
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:CEDefaultWindowAlphaKey];
    
    [self stopEditorInfoUpdateTimer];
}


// ------------------------------------------------------
/// prepare window and other UI
- (void)windowDidLoad
// ------------------------------------------------------
{
    [super windowDidLoad];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    [[self window] setContentSize:NSMakeSize((CGFloat)[defaults doubleForKey:CEDefaultWindowWidthKey],
                                             (CGFloat)[defaults doubleForKey:CEDefaultWindowHeightKey])];
    
    // setup background
    [(CEWindow *)[self window] setBackgroundAlpha:[defaults doubleForKey:CEDefaultWindowAlphaKey]];
    
    // setup document analyzer
    [[self documentAnalyzer] setDocument:[self document]];
    [[self documentInspectorViewController] setRepresentedObject:[self documentAnalyzer]];
    
    // setup sidebar
    [[[self sidebar] layer] setBackgroundColor:[[NSColor colorWithCalibratedWhite:0.94 alpha:1.0] CGColor]];
    // The following line is required for NSSplitView with Autolayout on OS X 10.8 (2015-02-10 by 1024jp)
    // Otherwise, visibility of splitView's subviews can not be initialized.
    [[self sidebarSplitView] layoutSubtreeIfNeeded];
    [self setSidebarShown:[defaults boolForKey:CEDefaultShowDocumentInspectorKey]];
    
    // set document instance to incompatible chars view
    [[self incompatibleCharsViewController] setRepresentedObject:[self document]];
    
    // set CEEditorWrapper to document instance
    [[self document] setEditor:[self editor]];
    [[self document] setStringToEditor];
    
    // setup status bar
    [[self statusBarController] setShown:[defaults boolForKey:CEDefaultShowStatusBarKey] animate:NO];
    
    [self updateFileInfo];
    [self updateModeInfoIfNeeded];
    
    // move focus to text view
    [[self window] makeFirstResponder:[[self editor] focusedTextView]];
    
    // notify finish of the document open process (Here is probably the final point.)
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CEDocumentDidFinishOpenNotification
                                                            object:weakSelf];
    });
    
    // observe sytnax style update
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(syntaxDidUpdate:)
                                                 name:CESyntaxDidUpdateNotification
                                               object:nil];
    
    // observe opacity setting change
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:CEDefaultWindowAlphaKey
                                               options:NSKeyValueObservingOptionNew
                                               context:nil];
}



#pragma mark Protocol

//=======================================================
// NSMenuValidation Protocol
//=======================================================

// ------------------------------------------------------
/// validate menu items
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
// ------------------------------------------------------
{
    if ([menuItem action] == @selector(toggleStatusBar:)) {
        NSString *title = [self showsStatusBar] ? @"Hide Status Bar" : @"Show Status Bar";
        [menuItem setTitle:NSLocalizedString(title, nil)];
    }
    
    return YES;
}


//=======================================================
// NSKeyValueObserving Protocol
//=======================================================

// ------------------------------------------------------
/// apply user defaults change
-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
// ------------------------------------------------------
{
    if ([keyPath isEqualToString:CEDefaultWindowAlphaKey]) {
        [(CEWindow *)[self window] setBackgroundAlpha:(CGFloat)[change[NSKeyValueChangeNewKey] doubleValue]];
    }
}


//=======================================================
// OgreTextFindDataSource Protocol
//=======================================================

// ------------------------------------------------------
/// OgreKit method that passes the main textView.
- (void)tellMeTargetToFindIn:(id)sender
// ------------------------------------------------------
{
    OgreTextFinder *textFinder = (OgreTextFinder *)sender;
    [textFinder setTargetToFindIn:[[self editor] focusedTextView]];
}



#pragma mark Public Methods

// ------------------------------------------------------
/// show incompatible char list
- (void)showIncompatibleCharList
// ------------------------------------------------------
{
    [self setSelectedSidebarTag:CEIncompatibleCharsTag];
    [self setSidebarShown:YES];
}


// ------------------------------------------------------
/// update incompatible char list if it is currently shown
- (void)updateIncompatibleCharsIfNeeded
// ------------------------------------------------------
{
    [[self incompatibleCharsViewController] updateIfNeeded];
}


// ------------------------------------------------------
/// update information about the content text in document inspector and status bar
- (void)updateEditorInfoIfNeeded
// ------------------------------------------------------
{
    BOOL updatesStatusBar = [[self statusBarController] isShown];
    BOOL updatesDrawer = [self isDocumentInspectorShown];
    
    if (!updatesStatusBar && !updatesDrawer) { return; }
    
    [[self documentAnalyzer] updateEditorInfo:updatesDrawer];
}


// ------------------------------------------------------
/// update information about file encoding and line endings in document inspector and status bar
- (void)updateModeInfoIfNeeded
// ------------------------------------------------------
{
    BOOL updatesStatusBar = [[self statusBarController] isShown];
    BOOL updatesDrawer = [self isDocumentInspectorShown];
    
    if (!updatesStatusBar && !updatesDrawer) { return; }
    
    [[self documentAnalyzer] updateModeInfo];
}


// ------------------------------------------------------
/// update information about file in document inspector and status bar
- (void)updateFileInfo
// ------------------------------------------------------
{
    [[self documentAnalyzer] updateFileInfo];
}


// ------------------------------------------------------
/// set update timer for information about the content text
- (void)setupEditorInfoUpdateTimer
// ------------------------------------------------------
{
    if ([self editorInfoUpdateTimer]) {
        [[self editorInfoUpdateTimer] setFireDate:[NSDate dateWithTimeIntervalSinceNow:infoUpdateInterval]];
    } else {
        [self setEditorInfoUpdateTimer:[NSTimer scheduledTimerWithTimeInterval:infoUpdateInterval
                                                                        target:self
                                                                      selector:@selector(updateEditorInfoWithTimer:)
                                                                      userInfo:nil
                                                                       repeats:NO]];
    }
}



#pragma mark Public Accessors

// ------------------------------------------------------
/// return whether status bar is shown
- (BOOL)showsStatusBar
// ------------------------------------------------------
{
    return [[self statusBarController] isShown];
}


// ------------------------------------------------------
/// set visibility of status bar
- (void)setShowsStatusBar:(BOOL)showsStatusBar
// ------------------------------------------------------
{
    if (![self statusBarController]) { return; }
    
    [[self statusBarController] setShown:showsStatusBar animate:YES];
    [[self toolbarController] toggleItemWithTag:CEToolbarShowStatusBarItemTag
                                          setOn:showsStatusBar];
    
    if (showsStatusBar) {
        [[self documentAnalyzer] updateEditorInfo:NO];
        [[self documentAnalyzer] updateFileInfo];
        [[self documentAnalyzer] updateModeInfo];
    }
}



#pragma mark Delegate

//=======================================================
// NSWindowDelegate  < window
//=======================================================

// ------------------------------------------------------
/// window becomes key window
- (void)windowDidBecomeKey:(NSNotification *)notification
// ------------------------------------------------------
{
    // do nothing if any sheet is attached
    if ([[self window] attachedSheet]) { return; }
    
    // update and style name and highlight if recolor flag is set
    if ([self needsRecolorWithBecomeKey]) {
        [self setNeedsRecolorWithBecomeKey:NO];
        [[self document] doSetSyntaxStyle:[[self editor] syntaxStyleName]];
    }
}


// ------------------------------------------------------
/// save window state on application termination
- (void)window:(NSWindow *)window willEncodeRestorableState:(NSCoder *)state
// ------------------------------------------------------
{
    [state encodeBool:[[self statusBarController] isShown] forKey:CEDefaultShowStatusBarKey];
    [state encodeBool:[[self editor] showsNavigationBar] forKey:CEDefaultShowNavigationBarKey];
    [state encodeBool:[[self editor] showsLineNum] forKey:CEDefaultShowLineNumbersKey];
    [state encodeBool:[[self editor] showsPageGuide] forKey:CEDefaultShowPageGuideKey];
    [state encodeBool:[[self editor] showsInvisibles] forKey:CEDefaultShowInvisiblesKey];
    [state encodeBool:[[self editor] isVerticalLayoutOrientation] forKey:CEDefaultLayoutTextVerticalKey];
    [state encodeBool:[self isSidebarShown] forKey:CEDefaultShowDocumentInspectorKey];
    [state encodeDouble:[self sidebarWidth] forKey:CEDefaultSidebarWidthKey];
}


// ------------------------------------------------------
/// restore window state from the last session
- (void)window:(NSWindow *)window didDecodeRestorableState:(NSCoder *)state
// ------------------------------------------------------
{
    if ([state containsValueForKey:CEDefaultShowStatusBarKey]) {
        [[self statusBarController] setShown:[state decodeBoolForKey:CEDefaultShowStatusBarKey] animate:NO];
    }
    if ([state containsValueForKey:CEDefaultShowNavigationBarKey]) {
        [[self editor] setShowsNavigationBar:[state decodeBoolForKey:CEDefaultShowNavigationBarKey] animate:NO];
    }
    if ([state containsValueForKey:CEDefaultShowLineNumbersKey]) {
        [[self editor] setShowsLineNum:[state decodeBoolForKey:CEDefaultShowLineNumbersKey]];
    }
    if ([state containsValueForKey:CEDefaultShowPageGuideKey]) {
        [[self editor] setShowsPageGuide:[state decodeBoolForKey:CEDefaultShowPageGuideKey]];
    }
    if ([state containsValueForKey:CEDefaultShowInvisiblesKey]) {
        [[self editor] setShowsInvisibles:[state decodeBoolForKey:CEDefaultShowInvisiblesKey]];
    }
    if ([state containsValueForKey:CEDefaultLayoutTextVerticalKey]) {
        [[self editor] setVerticalLayoutOrientation:[state decodeBoolForKey:CEDefaultLayoutTextVerticalKey]];
    }
    if ([state containsValueForKey:CEDefaultShowDocumentInspectorKey]) {
        [self setSidebarWidth:[state decodeDoubleForKey:CEDefaultSidebarWidthKey]];
        [self setSidebarShown:[state decodeBoolForKey:CEDefaultShowDocumentInspectorKey]];
    }
}


//=======================================================
// NSSplitViewDelegate  < sidebarSplitView
//=======================================================

// ------------------------------------------------------
/// only sidebar can collapse
- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview
// ------------------------------------------------------
{
    return (subview == [self sidebar]);
}


// ------------------------------------------------------
/// hide sidebar divider when collapsed
- (BOOL)splitView:(NSSplitView *)splitView shouldHideDividerAtIndex:(NSInteger)dividerIndex
// ------------------------------------------------------
{
    return YES;
}


// ------------------------------------------------------
/// store current sidebar width
- (void)splitViewDidResizeSubviews:(NSNotification *)notification
// ------------------------------------------------------
{
    if ([notification userInfo][@"NSSplitViewDividerIndex"]) {  // check wheter the change coused by user's divider dragging
        if ([self isSidebarShown]) {
            CGFloat currentWidth = NSWidth([[self sidebar] bounds]);
            [self setSidebarWidth:currentWidth];
            [[NSUserDefaults standardUserDefaults] setDouble:currentWidth forKey:CEDefaultSidebarWidthKey];
        }
    }
}



#pragma mark Action Messages

// ------------------------------------------------------
/// toggle visibility of document inspector
- (IBAction)getInfo:(id)sender
// ------------------------------------------------------
{
    if ([self isDocumentInspectorShown]) {
        [self setSidebarShown:NO];
    } else {
        [self setSelectedSidebarTag:CEDocumentInspectorTag];
        [self setSidebarShown:YES];
    }
}


// ------------------------------------------------------
/// toggle visibility of incompatible chars list view
- (IBAction)toggleIncompatibleCharList:(id)sender
// ------------------------------------------------------
{
    if ([self isSidebarShown] && [self selectedSidebarTag] == CEIncompatibleCharsTag) {
        [self setSidebarShown:NO];
    } else {
        [self setSelectedSidebarTag:CEIncompatibleCharsTag];
        [self setSidebarShown:YES];
    }
}


// ------------------------------------------------------
/// toggle visibility of status bar
- (IBAction)toggleStatusBar:(id)sender
// ------------------------------------------------------
{
    [self setShowsStatusBar:![self showsStatusBar]];
}



#pragma mark Private Methods

// ------------------------------------------------------
/// set sidebar visibility
- (void)setSidebarShown:(BOOL)shown
// ------------------------------------------------------
{
    if ([self selectedSidebarTag] == 0) {
        [self setSelectedSidebarTag:CEDocumentInspectorTag];
    }
    if ([self isSidebarShown] == shown) { return; }
    
    BOOL isInitial = ![[self window] isVisible];  // on `windowDidLoad` and `window:didDecodeRestorableState:`
    BOOL isFullscreen = ([[self window] styleMask] & NSFullScreenWindowMask) == NSFullScreenWindowMask;
    BOOL changesWindowSize = !isInitial && !isFullscreen;
    CGFloat sidebarWidth = [self sidebarWidth] ?: [[NSUserDefaults standardUserDefaults] doubleForKey:CEDefaultSidebarWidthKey];
    CGFloat dividerThickness = [[self sidebarSplitView] dividerThickness];
    CGFloat position = [[self sidebarSplitView] maxPossiblePositionOfDividerAtIndex:0];
    
    // adjust divider position
    if ((changesWindowSize && !shown) || (!changesWindowSize && shown)) {
        position -= sidebarWidth;
    }
    
    // update window width
    if (changesWindowSize) {
        NSRect windowFrame = [[self window] frame];
        windowFrame.size.width += shown ? (sidebarWidth + dividerThickness) : - (sidebarWidth + dividerThickness);
        [[self window] setFrame:windowFrame display:NO];
    }
    
    // apply
    [[self sidebarSplitView] setPosition:position ofDividerAtIndex:0];
    [[self sidebarSplitView] adjustSubviews];
    
    if (!shown) {
        // clear incompatible chars markup
        [[self editor] clearAllMarkup];
    }
}


// ------------------------------------------------------
/// return whether sidebar is opened
- (BOOL)isSidebarShown
// ------------------------------------------------------
{
    return ![[self sidebarSplitView] isSubviewCollapsed:[self sidebar]];
}


// ------------------------------------------------------
/// return whether document inspector is shown
- (BOOL)isDocumentInspectorShown
// ------------------------------------------------------
{
    return ([self selectedSidebarTag] == CEDocumentInspectorTag && [self isSidebarShown]);
}


// ------------------------------------------------------
/// switch sidebar view
- (void)setSelectedSidebarTag:(CESidebarTag)tag
// ------------------------------------------------------
{
    NSViewController *viewController;
    switch (tag) {
        case CEDocumentInspectorTag:
            viewController = [self documentInspectorViewController];
            [[self documentAnalyzer] updateEditorInfo:YES];
            [[self documentAnalyzer] updateFileInfo];
            [[self documentAnalyzer] updateModeInfo];
            break;
            
        case CEIncompatibleCharsTag:
            viewController = [self incompatibleCharsViewController];
            [[self incompatibleCharsViewController] update];
            break;
    }
    
    if (_selectedSidebarTag == tag) { return; }
    
    _selectedSidebarTag = tag;
    
    // swap views
    NSView *placeholder = [self sidebarPlaceholderView];
    NSView *currentView = [[placeholder subviews] firstObject];
    NSView *newView = [viewController view];
    
    // transit with animation
    [newView setFrame:[currentView frame]];
    [[placeholder animator] replaceSubview:currentView with:newView];
    
    // update autolayout constrains
    NSDictionary *views = NSDictionaryOfVariableBindings(newView);
    [placeholder addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[newView]|" options:0 metrics:nil views:views]];
    [placeholder addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[newView]|" options:0 metrics:nil views:views]];
}


// ------------------------------------------------------
/// set a flag of syntax highlight update if corresponded style has been updated
- (void)syntaxDidUpdate:(NSNotification *)notification
// ------------------------------------------------------
{
    NSString *currentName = [[self editor] syntaxStyleName];
    NSString *oldName = [notification userInfo][CEOldNameKey];
    NSString *newName = [notification userInfo][CENewNameKey];
    
    if (![oldName isEqualToString:currentName]) { return; }
    
    if ([oldName isEqualToString:newName]) {
        [[self editor] setSyntaxStyleName:newName recolorNow:NO];
    }
    if (![newName isEqualToString:NSLocalizedString(@"None", nil)]) {
        if ([[self window] isKeyWindow]) {
            [[self document] doSetSyntaxStyle:newName];
        } else {
            [self setNeedsRecolorWithBecomeKey:YES];
        }
    }
}


// ------------------------------------------------------
/// editor info update timer is fired
- (void)updateEditorInfoWithTimer:(NSTimer *)timer
// ------------------------------------------------------
{
    [self stopEditorInfoUpdateTimer];
    [self updateEditorInfoIfNeeded];
}


// ------------------------------------------------------
/// stop editor info update timer
- (void)stopEditorInfoUpdateTimer
// ------------------------------------------------------
{
    if ([self editorInfoUpdateTimer]) {
        [[self editorInfoUpdateTimer] invalidate];
        [self setEditorInfoUpdateTimer:nil];
    }
}

@end
