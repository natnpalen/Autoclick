//
//  AutoclickAppDelegate.m
//  Autoclick
//

#import "AutoclickAppDelegate.h"
@import IOKit;
#import <ApplicationServices/ApplicationServices.h>

// Private extension so we don't need to edit the .h file
@interface AutoclickAppDelegate ()
@property (nonatomic, assign) BOOL ac_intervalModeEnabled;
@property (nonatomic, assign) NSInteger ac_intervalSeconds;
@property (nullable, nonatomic, strong) dispatch_source_t ac_intervalTimer;

// Optional UI (connect later in Xcode if you want on-screen controls)
@property (weak) IBOutlet NSButton *ac_intervalModeCheckbox;
@property (weak) IBOutlet NSTextField *ac_intervalMinutesField;

// Actions (connect later if you add UI)
- (IBAction)ac_toggleIntervalMode:(id)sender;
- (IBAction)ac_intervalMinutesChanged:(id)sender;

- (void)ac_updateUIForIntervalMode;
- (void)ac_startIntervalTimer;
- (void)ac_stopIntervalTimer;
- (void)ac_performSingleClick;
@end

@implementation NSApplication (AppDelegate)

- (AutoclickAppDelegate *)appDelegate {
    return (AutoclickAppDelegate *)[NSApp delegate];
}

@end

@implementation AutoclickAppDelegate {
    NSUserDefaultsController *_defaults;
}

@synthesize window;
@synthesize modeButton;
@synthesize statusLabel;
@synthesize startStopButton;

- (void)encodeRestorableState:(NSCoder *)state {
    [state encodeInteger:[buttonSelector indexOfSelectedItem] forKey:@"buttonSelector"];
    [state encodeInteger:[rateSelector integerValue] forKey:@"rateSelector"];
    [state encodeInteger:[rateUnitSelector indexOfSelectedItem] forKey:@"rateUnitSelector"];
    
    [state encodeInteger:[startAfterSelector integerValue] forKey:@"startAfterSelector"];
    [state encodeInteger:[startAfterUnitSelector indexOfSelectedItem] forKey:@"startAfterUnitSelector"];
    [state encodeBool:[startAfterCheckbox state] forKey:@"startAfterCheckbox"];
    
    [state encodeInteger:[stopAfterSelector integerValue] forKey:@"stopAfterSelector"];
    [state encodeInteger:[stopAfterUnitSelector indexOfSelectedItem] forKey:@"stopAfterUnitSelector"];
    [state encodeBool:[stopAfterCheckbox state] forKey:@"stopAfterCheckbox"];
    
    [state encodeBool:[ifStationaryCheckbox state] forKey:@"ifStationaryCheckbox"];
    [state encodeBool:[ifStationaryForCheckbox state] forKey:@"ifStationaryForCheckbox"];
    [state encodeInteger:[ifStationaryForSelector integerValue] forKey:@"ifStationaryForSelector"];
}

- (void)decodeRestorableState:(NSCoder *)state {
    [buttonSelector selectItemAtIndex:[state decodeIntegerForKey:@"buttonSelector"]];
    [rateSelector setIntegerValue:[state decodeIntegerForKey:@"rateSelector"]];
    [rateUnitSelector selectItemAtIndex:[state decodeIntegerForKey:@"rateUnitSelector"]];
    
    [startAfterSelector setIntegerValue:[state decodeIntegerForKey:@"startAfterSelector"]];
    [startAfterUnitSelector selectItemAtIndex:[state decodeIntegerForKey:@"startAfterUnitSelector"]];
    [startAfterCheckbox setState:[state decodeBoolForKey:@"startAfterCheckbox"]];
    
    [stopAfterSelector setIntegerValue:[state decodeIntegerForKey:@"stopAfterSelector"]];
    [stopAfterUnitSelector selectItemAtIndex:[state decodeIntegerForKey:@"stopAfterUnitSelector"]];
    [stopAfterCheckbox setState:[state decodeBoolForKey:@"stopAfterCheckbox"]];
    
    [ifStationaryCheckbox setState:[state decodeBoolForKey:@"ifStationaryCheckbox"]];
    [ifStationaryForCheckbox setState:[state decodeBoolForKey:@"ifStationaryForCheckbox"]];
    [ifStationaryForSelector setIntegerValue:[state decodeIntegerForKey:@"ifStationaryForSelector"]];
    
    [rateSelector syncWithStepper];
    [startAfterSelector syncWithStepper];
    [stopAfterSelector syncWithStepper];
    [ifStationaryForSelector syncWithStepper];
    
    [self changedState:ifStationaryCheckbox];
}

- (void)awakeFromNib {
    clicker = [[Clicker alloc] init];
    [window setDelegate:(id<NSWindowDelegate>)self];
    [rateSelector syncWithStepper];
    [startAfterSelector syncWithStepper];
    [stopAfterSelector syncWithStepper];
    [ifStationaryForSelector syncWithStepper];

    [shortcutRecorder setAllowedModifierFlags:SRCocoaModifierFlagsMask requiredModifierFlags:0 allowsEmptyModifierFlags:YES];

    _defaults = NSUserDefaultsController.sharedUserDefaultsController;
    NSString *keyPath = @"values.shortcut";
    NSDictionary *options = @{NSValueTransformerNameBindingOption: NSKeyedUnarchiveFromDataTransformerName};

    SRShortcutAction *shortcutAction = [SRShortcutAction shortcutActionWithKeyPath:keyPath
                                                                          ofObject:_defaults
                                                                     actionHandler:^BOOL(SRShortcutAction *anAction) {
        [[NSApp appDelegate] startStop:nil];
        return YES;
    }];
    [[SRGlobalShortcutMonitor sharedMonitor] addAction:shortcutAction forKeyEvent:SRKeyEventTypeDown];

    [shortcutRecorder bind:NSValueBinding toObject:_defaults withKeyPath:keyPath options:options];
    
    // Position the mode button in the titlebar
    NSView *frameView = [[window contentView] superview];
    [frameView addSubview:modeButton];
    [modeButton setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [modeButton.trailingAnchor constraintEqualToAnchor:frameView.trailingAnchor constant:-6],
        [modeButton.topAnchor constraintEqualToAnchor:frameView.topAnchor constant:6]
    ]];
    
    if (![userDefaults boolForKey:@"Advanced"])
        [self setMode:NO];
    else
        [self setMode:YES];

    NSData* data = [userDefaults objectForKey:@"State"];
    if (data)
    {
        NSKeyedUnarchiver* unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:nil];
        [self decodeRestorableState:unarchiver];
    }
    
    [window setDelegate:(id<NSWindowDelegate>)self];

    // --- Interval mode defaults & UI reflection ---
    self.ac_intervalModeEnabled = [userDefaults boolForKey:@"ACIntervalModeEnabled"];
    NSInteger s = (NSInteger)[userDefaults integerForKey:@"ACIntervalSeconds"];
    if (s <= 0) s = 60; // default: 1 minute
    self.ac_intervalSeconds = s;

    if (self.ac_intervalModeCheckbox) {
        self.ac_intervalModeCheckbox.state = self.ac_intervalModeEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.ac_intervalMinutesField) {
        NSInteger minutes = MAX(1, (NSInteger)llround((double)self.ac_intervalSeconds / 60.0));
        self.ac_intervalMinutesField.integerValue = minutes;
    }
    [self ac_updateUIForIntervalMode];
}

- (void)windowWillClose:(NSNotification*)note {
    @try {
        NSMenuItem* windowMenuItem = [[NSApp mainMenu] itemAtIndex:[[[NSApp mainMenu] itemArray] count]-2];
        
        NSMenuItem* separator = [NSMenuItem separatorItem];
        NSMenuItem* showAutoclick = [[NSMenuItem alloc] initWithTitle:@"Show Autoclick" action:@selector(applicationShouldHandleReopen:hasVisibleWindows:) keyEquivalent:@""];
        
        [[windowMenuItem submenu] insertItem:separator atIndex:0];
        [[windowMenuItem submenu] insertItem:showAutoclick atIndex:0];
    }
    @catch (NSException *exception) {
        
    }
}

- (void)windowDidBecomeKey:(NSNotification*)note {
    @try {
        NSMenuItem* windowMenuItem = [[NSApp mainMenu] itemAtIndex:[[[NSApp mainMenu] itemArray] count]-2];
        
        NSMenu* submenu = [windowMenuItem submenu];
        if ([[[submenu itemAtIndex:0] title] isEqualToString:@"Show Autoclick"])
        {
            [submenu removeItemAtIndex:0];
            [submenu removeItemAtIndex:0];
        }
    }
    @catch (NSException *exception) {
        
    }
}

- (IBAction)changeMode:(id)sender {
    [self setMode:!mode];
}

/* val: YES = Advanced / NO = Basic */
- (void)setMode:(BOOL)val {
    if (!val)
    {
        [modeButton setTitle:@"Basic"];
                
        [[advancedBox subviews] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop){
            [obj setHidden:YES];
        }];
                
        NSRect frame = [window frame];
        if (frame.size.height >= 400)
        {
            frame.size.height = 217;
            frame.origin.y += 415 - 217;

            [window setFrame:frame display:YES animate:YES];
        }
    }
    else
    {
        [modeButton setTitle:@"Advanced"];
                
        [[advancedBox subviews] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop){
            [obj setHidden:NO];
        }];
        
        NSRect frame = [window frame];
        if (frame.size.height <= 300)
        {
            frame.size.height = 415;
            frame.origin.y -= 415 - 217;

            [window setFrame:frame display:YES animate:YES];    
        }
    }
    
    mode = val;
    [userDefaults setBool:val forKey:@"Advanced"];
}

- (IBAction)startStop:(id)sender {
    // If we're currently clicking OR running interval mode, stop everything.
    if ([clicker isClicking] || self.ac_intervalTimer) {
        if ([clicker isClicking]) {
            [clicker stopClicking];
        }
        if (self.ac_intervalTimer) {
            [self ac_stopIntervalTimer];
        }
        [self stoppedClicking];
        return;
    }

    NSDictionary *options = @{(__bridge id) kAXTrustedCheckOptionPrompt : @YES};
    BOOL accessibilityEnabled = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);

    if (!accessibilityEnabled) {
        // Do not enable clicking if accessibility is off because the user might open the Privacy > Accessibility
        // settings then check the box next to Autoclick which will immediately be unchecked by the automatic
        // clicking.
        return;
    }

    if (@available(macOS 10.15, *)) {
        BOOL inputMonitoringEnabled = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;

        // If Input Monitoring is off (should be 'Granted' when Accessibility is checked), request it
        if (!inputMonitoringEnabled) {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);

            // Do not enable clicking because the user might not have a way to stop the clicking because the FN
            // key will not be detected and they might not have a keyboard shortcut set (which might not be detected
            // either)
            return;
        }
    }

    // NEW: interval mode path (low-frequency single click every N minutes)
    if (self.ac_intervalModeEnabled) {
        [self ac_startIntervalTimer];
        [self startedClicking]; // updates UI to "Stop"
        return;
    }

    // Button
    int selectedButton;
    switch ([buttonSelector indexOfSelectedItem]) {
        case 0: selectedButton = LEFT; break;
        case 1: selectedButton = RIGHT; break;
        case 2: selectedButton = MIDDLE; break;
        default: selectedButton = LEFT; break;
    }
    
    // Rate
    NSInteger selectedRate = [rateSelector intValue];
    NSInteger selectedRateUnit = ([rateUnitSelector indexOfSelectedItem]==0)?1000:60000;

    double rate = selectedRateUnit / selectedRate; // a click every 'rate' (in ms)
    
    // Start Clicking or add the advanced preferences ?
    if (!mode)
        [clicker startClicking:selectedButton rate:rate startAfter:0 stopAfter:0 ifStationaryFor:0];
    else
    {
        NSInteger startAfter = ([startAfterCheckbox state])?([startAfterSelector intValue]*(([startAfterUnitSelector indexOfSelectedItem]==0)?1:60)):0;
                    
        NSInteger stopAfter = ([stopAfterCheckbox state])?([stopAfterSelector intValue]*(([stopAfterUnitSelector indexOfSelectedItem]==0)?1:60)):0;
                    
        NSInteger stationaryFor = ([ifStationaryCheckbox state])?([ifStationaryForCheckbox state]?[ifStationaryForSelector intValue]:1):0;
        
        [clicker startClicking:selectedButton rate:rate startAfter:startAfter stopAfter:stopAfter ifStationaryFor:stationaryFor];
    }
    
    [self startedClicking];
}

- (void)startedClicking {
    [modeButton setEnabled:NO];
    [startStopButton setTitle:@"Stop"];
}

- (void)stoppedClicking {
    [modeButton setEnabled:YES];
    [startStopButton setTitle:@"Start"];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    // Insert code here to initialize your application
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [window makeKeyAndOrderFront:self];
    
    return YES;
}

- (IBAction)applicationShouldHandleReopen:(id)sender {
    [self applicationShouldHandleReopen:NSApp hasVisibleWindows:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSKeyedArchiver* archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [self encodeRestorableState:archiver];
    [archiver finishEncoding];

    [userDefaults setObject:archiver.encodedData forKey:@"State"];
}

- (IBAction)changedState:(id)sender {
    if (sender == ifStationaryCheckbox)
    {
        [ifStationaryForCheckbox setEnabled:[ifStationaryCheckbox state]];
        [ifStationaryForSelector setEnabled:[ifStationaryCheckbox state]];
        [[ifStationaryForSelector stepper] setEnabled:[ifStationaryCheckbox state]];
        
        if ([ifStationaryCheckbox state])
            [ifStationaryForText setTextColor:[NSColor textColor]];
        else
            [ifStationaryForText setTextColor:[NSColor disabledControlTextColor]];
    }
}

- (id)init {
    self = [super init];
    
    if (self)
    {
        userDefaults = [NSUserDefaults standardUserDefaults];
        iconArray = [NSArray arrayWithObjects:[NSImage imageNamed:@"clicking.icns"], [NSImage imageNamed:@"clicking1.icns"], [NSImage imageNamed:@"clicking2.icns"], [NSImage imageNamed:@"clicking3.icns"], nil];
        iconTimer = nil;
        [self defaultIcon];
        clicker = nil;
    }
    
    return self;
}

#pragma mark - Help & Support

- (IBAction)openGitHub:(id)sender {
    NSURL *url = [NSURL URLWithString:@"https://github.com/inket/Autoclick"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - Icon Handling

- (void)defaultIcon {
    if (DEBUG_ENABLED) NSLog(@"defaultIcon call");
    [iconTimer invalidate];
    [NSApp setApplicationIconImage:[NSImage imageNamed:@"default.icns"]];
}

- (void)pausedIcon {
    if (DEBUG_ENABLED) NSLog(@"pausedIcon call");
    [iconTimer invalidate];
    [NSApp setApplicationIconImage:[NSImage imageNamed:@"paused.icns"]];
}

- (void)waitingIcon {
    if (DEBUG_ENABLED) NSLog(@"waitingIcon call");
    [iconTimer invalidate];
    [NSApp setApplicationIconImage:[NSImage imageNamed:@"waiting.icns"]];
}

- (void)clickingIcon {
    if (DEBUG_ENABLED) NSLog(@"clickingIcon call");
    if (!iconTimer || ![iconTimer isValid])
    {
        iconIndex = 1;
        [NSApp setApplicationIconImage:[iconArray objectAtIndex:0]];
        iconTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(nextIcon) userInfo:nil repeats:YES];
    }
}
                     
- (void)nextIcon {
    if (DEBUG_ENABLED) NSLog(@"nextIcon call");
    iconIndex++;
    if (iconIndex >= [iconArray count]) iconIndex = 0;
    [NSApp setApplicationIconImage:[iconArray objectAtIndex:iconIndex]];
}

// =======================
// Interval Mode support
// =======================
static NSString * const kACIntervalModeEnabledKey = @"ACIntervalModeEnabled";
static NSString * const kACIntervalSecondsKey     = @"ACIntervalSeconds";

- (void)ac_updateUIForIntervalMode
{
    BOOL interval = self.ac_intervalModeEnabled;

    // Optional UI controls if you connect them later
    if (self.ac_intervalMinutesField) self.ac_intervalMinutesField.enabled = interval;
    if (self.ac_intervalModeCheckbox) self.ac_intervalModeCheckbox.state = interval ? NSControlStateValueOn : NSControlStateValueOff;

    // Disable CPS controls when interval mode is on (so users don’t change both)
    if (rateSelector)      [rateSelector setEnabled:!interval];
    if (rateUnitSelector)  [rateUnitSelector setEnabled:!interval];
}

- (IBAction)ac_toggleIntervalMode:(id)sender
{
    self.ac_intervalModeEnabled = (self.ac_intervalModeCheckbox.state == NSControlStateValueOn);
    [userDefaults setBool:self.ac_intervalModeEnabled forKey:kACIntervalModeEnabledKey];
    [self ac_updateUIForIntervalMode];

    // If user disables while running, stop the timer
    if (!self.ac_intervalModeEnabled && self.ac_intervalTimer) {
        [self ac_stopIntervalTimer];
        [self stoppedClicking];
    }
}

- (IBAction)ac_intervalMinutesChanged:(id)sender
{
    NSInteger minutes = self.ac_intervalMinutesField.integerValue;
    if (minutes < 1) minutes = 1;

    NSInteger seconds = minutes * 60;
    if (seconds > 24 * 60 * 60) seconds = 24 * 60 * 60; // clamp to 24h

    self.ac_intervalSeconds = seconds;
    [userDefaults setInteger:self.ac_intervalSeconds forKey:kACIntervalSecondsKey];

    // If timer is running, reschedule with new interval
    if (self.ac_intervalTimer) {
        [self ac_startIntervalTimer];
    }
}

- (void)ac_startIntervalTimer
{
    [self ac_stopIntervalTimer];

    if (self.ac_intervalSeconds < 1) self.ac_intervalSeconds = 1;

    dispatch_queue_t q = dispatch_get_main_queue();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);

    uint64_t interval_ns = (uint64_t)self.ac_intervalSeconds * (uint64_t)NSEC_PER_SEC;
    uint64_t leeway_ns   = (uint64_t)(0.5 * (double)NSEC_PER_SEC); // allow 0.5s jitter to save CPU

    // First click after one interval; change DISPATCH_TIME_NOW to 0 for immediate first click
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, interval_ns),
                              interval_ns,
                              leeway_ns);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf ac_performSingleClick];
    });

    self.ac_intervalTimer = timer;
    dispatch_resume(timer);
}

- (void)ac_stopIntervalTimer
{
    if (self.ac_intervalTimer) {
        dispatch_source_cancel(self.ac_intervalTimer);
        self.ac_intervalTimer = nil;
    }
}

- (void)ac_performSingleClick
{
    // Current cursor position
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return;
    CGPoint p = CGEventGetLocation(event);
    CFRelease(event);

    // Respect the current button selection (0=left, 1=right, 2=middle)
    NSInteger idx = [buttonSelector indexOfSelectedItem];
    CGMouseButton btn = kCGMouseButtonLeft;
    CGEventType downT = kCGEventLeftMouseDown;
    CGEventType upT   = kCGEventLeftMouseUp;

    if (idx == 1) { btn = kCGMouseButtonRight;  downT = kCGEventRightMouseDown; upT = kCGEventRightMouseUp; }
    else if (idx == 2) { btn = kCGMouseButtonCenter; downT = kCGEventOtherMouseDown; upT = kCGEventOtherMouseUp; }

    CGEventRef down = CGEventCreateMouseEvent(NULL, downT, p, btn);
    CGEventRef up   = CGEventCreateMouseEvent(NULL, upT,   p, btn);
    if (down && up) {
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up)   CFRelease(up);
}

@end
