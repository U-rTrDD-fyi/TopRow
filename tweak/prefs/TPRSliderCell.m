#import <Preferences/PSSliderTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>

// Slider with an editable whole-number box in place of the stock value label:
// dragging updates the box, typing a number moves the slider. Values go through the
// pane's setPreferenceValue:specifier:, which validates the range.
@interface TPRSliderCell : PSSliderTableCell <UITextFieldDelegate>
@end

@implementation TPRSliderCell {
    UITextField *_field;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier])) {
        _field = [UITextField new];
        _field.keyboardType = UIKeyboardTypeNumberPad;
        _field.textAlignment = NSTextAlignmentCenter;
        _field.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular];
        _field.borderStyle = UITextBorderStyleRoundedRect;
        _field.delegate = self;
        UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
        bar.items = @[ [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
                       [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:_field
                                                                     action:@selector(resignFirstResponder)] ];
        [bar sizeToFit];
        _field.inputAccessoryView = bar;
        [self.contentView addSubview:_field];
    }
    return self;
}

- (UISlider *)slider {
    return [self.control isKindOfClass:[UISlider class]] ? (UISlider *)self.control : nil;
}

- (void)showSliderValue {
    if (!_field.isEditing) _field.text = [NSString stringWithFormat:@"%.0f", round(self.slider.value)];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self showSliderValue];
}

- (void)controlChanged:(UIControl *)control {
    // Whole percentages only, so the box always shows exactly what's applied.
    self.slider.value = round(self.slider.value);
    [super controlChanged:control];
    // Even mid-edit: the drag wins, and ending the edit then saves the same value.
    _field.text = [NSString stringWithFormat:@"%.0f", self.slider.value];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat width = 56, margin = 16;
    _field.frame = CGRectMake(CGRectGetMaxX(bounds) - margin - width, CGRectGetMidY(bounds) - 16, width, 32);
    UISlider *slider = self.slider;
    CGRect frame = slider.frame;
    frame.size.width = CGRectGetMinX(_field.frame) - 12 - frame.origin.x;
    slider.frame = frame;
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    NSInteger value = field.text.integerValue;
    PSSpecifier *specifier = self.specifier;
    id target = specifier.target;
    if (field.text.length && [target respondsToSelector:@selector(setPreferenceValue:specifier:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(target, @selector(setPreferenceValue:specifier:), @(value), specifier);  // validates; alerts if out of range
        if (value >= self.slider.minimumValue && value <= self.slider.maximumValue) self.slider.value = value;
    }
    [self showSliderValue];
}

@end
