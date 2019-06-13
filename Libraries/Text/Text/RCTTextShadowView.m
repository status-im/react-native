/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTTextShadowView.h"

#import <React/RCTBridge.h>
#import <React/RCTShadowView+Layout.h>
#import <React/RCTUIManager.h>
#import <yoga/Yoga.h>

#import "NSTextStorage+FontScaling.h"
#import "RCTTextView.h"

@implementation RCTTextShadowView
{
  __weak RCTBridge *_bridge;
  BOOL _needsUpdateView;
  NSMapTable<id, NSTextStorage *> *_cachedTextStorages;
}

- (instancetype)initWithBridge:(RCTBridge *)bridge
{
  if (self = [super init]) {
    _bridge = bridge;
    _cachedTextStorages = [NSMapTable strongToStrongObjectsMapTable];
    _needsUpdateView = YES;
    YGNodeSetMeasureFunc(self.yogaNode, RCTTextShadowViewMeasure);
    YGNodeSetBaselineFunc(self.yogaNode, RCTTextShadowViewBaseline);
  }

  return self;
}

- (void)didSetProps:(NSArray<NSString *> *)changedProps
{
  [super didSetProps:changedProps];

  self.textAttributes.opacity = NAN;
}

- (BOOL)isYogaLeafNode
{
  return YES;
}

- (void)dirtyLayout
{
  [super dirtyLayout];
  YGNodeMarkDirty(self.yogaNode);
  [self invalidateCache];
}

- (void)invalidateCache
{
  [_cachedTextStorages removeAllObjects];
  _needsUpdateView = YES;
}

#pragma mark - RCTUIManagerObserver

- (void)uiManagerWillPerformMounting
{
  if (YGNodeIsDirty(self.yogaNode)) {
    return;
  }

  if (!_needsUpdateView) {
    return;
  }
  _needsUpdateView = NO;

  CGRect contentFrame = self.contentFrame;
  NSTextStorage *textStorage = [self textStorageAndLayoutManagerThatFitsSize:self.contentFrame.size
                                                          exclusiveOwnership:YES];

  NSNumber *tag = self.reactTag;
  NSMutableArray<NSNumber *> *descendantViewTags = [NSMutableArray new];
  [textStorage enumerateAttribute:RCTBaseTextShadowViewEmbeddedShadowViewAttributeName
                          inRange:NSMakeRange(0, textStorage.length)
                          options:0
                       usingBlock:
   ^(RCTShadowView *shadowView, NSRange range, __unused BOOL *stop) {
     if (!shadowView) {
       return;
     }

     [descendantViewTags addObject:shadowView.reactTag];
   }
  ];

  [_bridge.uiManager addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {
    RCTTextView *textView = (RCTTextView *)viewRegistry[tag];
    if (!textView) {
      return;
    }

    NSMutableArray<UIView *> *descendantViews =
      [NSMutableArray arrayWithCapacity:descendantViewTags.count];
    [descendantViewTags enumerateObjectsUsingBlock:^(NSNumber *_Nonnull descendantViewTag, NSUInteger index, BOOL *_Nonnull stop) {
      UIView *descendantView = viewRegistry[descendantViewTag];
      if (!descendantView) {
        return;
      }

      [descendantViews addObject:descendantView];
    }];

    // Removing all references to Shadow Views to avoid unnececery retainning.
    [textStorage removeAttribute:RCTBaseTextShadowViewEmbeddedShadowViewAttributeName range:NSMakeRange(0, textStorage.length)];

    [textView setTextStorage:textStorage
                contentFrame:contentFrame
             descendantViews:descendantViews];
  }];
}

- (void)postprocessAttributedText:(NSMutableAttributedString *)attributedText
{
  __block CGFloat maximumLineHeight = 0;

  [attributedText enumerateAttribute:NSParagraphStyleAttributeName
                             inRange:NSMakeRange(0, attributedText.length)
                             options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
                          usingBlock:
    ^(NSParagraphStyle *paragraphStyle, __unused NSRange range, __unused BOOL *stop) {
      if (!paragraphStyle) {
        return;
      }

      maximumLineHeight = MAX(paragraphStyle.maximumLineHeight, maximumLineHeight);
    }
  ];

  if (maximumLineHeight == 0) {
    // `lineHeight` was not specified, nothing to do.
    return;
  }

  __block CGFloat maximumFontLineHeight = 0;

  [attributedText enumerateAttribute:NSFontAttributeName
                             inRange:NSMakeRange(0, attributedText.length)
                             options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
                          usingBlock:
    ^(UIFont *font, NSRange range, __unused BOOL *stop) {
      if (!font) {
        return;
      }

      if (maximumFontLineHeight <= font.lineHeight) {
        maximumFontLineHeight = font.lineHeight;
      }
    }
  ];

  if (maximumLineHeight < maximumFontLineHeight) {
    return;
  }

  CGFloat baseLineOffset = maximumLineHeight / 2.0 - maximumFontLineHeight / 2.0;

  [attributedText addAttribute:NSBaselineOffsetAttributeName
                         value:@(baseLineOffset)
                         range:NSMakeRange(0, attributedText.length)];

  if (!_parseBasicMarkdown) {
    return;
  }

  UIFontDescriptorSymbolicTraits traitZones[attributedText.string.length];
  for (int i = 0; i < attributedText.string.length; i++) {
    traitZones[i] = 0;
  }

  [self parseMarkdownTag:@"```"
                  inText:attributedText
              fontTraits:UIFontDescriptorTraitMonoSpace
                 fgColor:self.markdownCodeForegroundColor
                 bgColor:self.markdownCodeBackgroundColor
               codeZones:traitZones];

  [self parseMarkdownTag:@"`"
                  inText:attributedText
              fontTraits:UIFontDescriptorTraitMonoSpace
                 fgColor:self.markdownCodeForegroundColor
                 bgColor:self.markdownCodeBackgroundColor
               codeZones:traitZones];

  [self parseMarkdownTag:@"*"
                  inText:attributedText
              fontTraits:UIFontDescriptorTraitBold
                 fgColor:nil
                 bgColor:nil
               codeZones:traitZones];

  [self parseMarkdownTag:@"_"
                  inText:attributedText
              fontTraits:UIFontDescriptorTraitItalic
                 fgColor:nil
                 bgColor:nil
              codeZones:traitZones];
}


- (UIFont *)fontWithTraits:(UIFontDescriptorSymbolicTraits)traits fromFont:(UIFont *)font
{
  if (traits == UIFontDescriptorTraitMonoSpace) {
    return [UIFont fontWithName:@"Menlo" size:font.pointSize];
  }

  UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits|traits];
  if (!descriptor) {
    return font;
  }
  return [UIFont fontWithDescriptor:descriptor size:font.pointSize];
}

-(bool)isWhitespaceOrControlCharacter:(unichar)character {
  return character == ' ' ||
    character == '\n' ||
    character == [@"\u200B" characterAtIndex:0] ||
    character == '_' ||
    character == '*' ||
    character == '`';
}

-(void)applyFontAttributeToString:(NSMutableAttributedString *)attributedText
                          inRange:(NSRange)range
                       fontTraits:(UIFontDescriptorSymbolicTraits)fontTraits
                        allTraits:(UIFontDescriptorSymbolicTraits *)allTraits {
  UIFont *font = [attributedText attribute:NSFontAttributeName atIndex:range.location effectiveRange:nil];
  if (!font) {
    font = [UIFont systemFontOfSize:18];
  }

  UIFontDescriptorSymbolicTraits prevTraits = allTraits[range.location];
  NSInteger rangeStart = range.location;
  for (NSUInteger i = range.location; i < range.location + range.length; i++) {
    UIFontDescriptorSymbolicTraits currentTraits = allTraits[i];
    if (currentTraits != prevTraits) {
      NSRange subrange = NSMakeRange(rangeStart, i - rangeStart);
      [self applyTraitsToSubrangeOfString:attributedText
                                 subrange:subrange
                               prevTraits:prevTraits
                                     font:font
                           incomingTraits:fontTraits];

      prevTraits = currentTraits;
      rangeStart = i;
    }
  }
  NSRange subrange = NSMakeRange(rangeStart, range.location + range.length - rangeStart);

  [self applyTraitsToSubrangeOfString:attributedText
                             subrange:subrange
                           prevTraits:prevTraits
                                 font:font
                       incomingTraits:fontTraits];
}

-(void)applyTraitsToSubrangeOfString:(NSMutableAttributedString *)attributedText
                            subrange:(NSRange)subrange
                          prevTraits:(UIFontDescriptorSymbolicTraits)prevTraits
                                font:(UIFont *)font
                      incomingTraits:(UIFontDescriptorSymbolicTraits)incomingTraits
{
  // don't override monospace, ever
  UIFontDescriptorSymbolicTraits traitsToApply =
    prevTraits & UIFontDescriptorTraitMonoSpace ? prevTraits : prevTraits|incomingTraits;
  font = [self fontWithTraits:traitsToApply fromFont:font];
  [attributedText addAttribute:NSFontAttributeName value:font range:subrange];
}

-(void)parseMarkdownTag:(NSString *)tag
                 inText:(NSMutableAttributedString *)attributedText
             fontTraits:(UIFontDescriptorSymbolicTraits)traits
                fgColor:(UIColor *)fgColor
                bgColor:(UIColor *)bgColor
              codeZones:(UIFontDescriptorSymbolicTraits *)codeZones
{
  NSInteger start = NSNotFound;
  bool multilineCodeTag = [tag isEqualToString:@"```"];

  for (NSInteger i = 0; i < attributedText.string.length - tag.length; i++) {

    NSString *candidate = [attributedText.string substringWithRange:NSMakeRange(i, tag.length)];

    bool isInCodeZone = codeZones[i] & UIFontDescriptorTraitMonoSpace;

    if ([candidate isEqualToString:tag]) {
      unichar nextCharacter = [attributedText.string characterAtIndex:i+tag.length];
      bool followedByWhitespace = nextCharacter == ' ' || nextCharacter == '\n';
      bool followedByControlCharacter = [self isWhitespaceOrControlCharacter:nextCharacter];

      bool preceededByWhitespaceOrControlCharacter = i == 0 || [self isWhitespaceOrControlCharacter:[attributedText.string characterAtIndex:i - 1]];

      if (start == NSNotFound && !isInCodeZone) {
        if (attributedText.string.length - i > tag.length) {
          if ((!followedByWhitespace || multilineCodeTag) && preceededByWhitespaceOrControlCharacter) {
            start = i;

            // the ``` tag needs to be outermost
            if (multilineCodeTag) {
              i += tag.length - 1;
            }
          }
        }
      } else if(start != NSNotFound && !isInCodeZone) {
        if (i - start < 2) {
          // multilineCodeTag should be outermost
          if(!followedByWhitespace && !multilineCodeTag) {
            start = i;
          } else {
            start = NSNotFound;
          }
        } else if(followedByWhitespace || (!multilineCodeTag && followedByControlCharacter)) {
          NSRange range = NSMakeRange(start, i-start+tag.length);
          // iOS doesn't support merging font traits natively, so we are doing it manually here
          [self applyFontAttributeToString:attributedText inRange:range fontTraits:traits allTraits:codeZones];

          if (fgColor) {
            [attributedText addAttribute:NSForegroundColorAttributeName value:fgColor range:range];
          }

          if (bgColor) {
            [attributedText addAttribute:NSBackgroundColorAttributeName value:bgColor range:range];
          }

          // replacing control characters with 0-width spaces to hide them
          NSString *replacement = @"";
          for (int j = 0; j < tag.length; j++) {
            replacement = [replacement stringByAppendingString:@"\u200B"];
          }
          [attributedText replaceCharactersInRange:NSMakeRange(i, tag.length) withString:replacement];
          [attributedText replaceCharactersInRange:NSMakeRange(start, tag.length) withString:replacement];

          for (NSInteger j = start; j < i + tag.length; j++) {
            codeZones[j] |= traits;
          }

          start = NSNotFound;
        }
      }
    } else if ([candidate isEqualToString:@"\n"] && !multilineCodeTag) {
      // resetting tags on line breaks (except ```)
      start = NSNotFound;
    }
  }
}

- (NSAttributedString *)attributedTextWithMeasuredAttachmentsThatFitSize:(CGSize)size
{
  NSMutableAttributedString *attributedText =
    [[NSMutableAttributedString alloc] initWithAttributedString:[self attributedTextWithBaseTextAttributes:nil]];

  [attributedText beginEditing];

  [attributedText enumerateAttribute:RCTBaseTextShadowViewEmbeddedShadowViewAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:
    ^(RCTShadowView *shadowView, NSRange range, __unused BOOL *stop) {
      if (!shadowView) {
        return;
      }

      CGSize fittingSize = [shadowView sizeThatFitsMinimumSize:CGSizeZero
                                                   maximumSize:size];
      NSTextAttachment *attachment = [NSTextAttachment new];
      attachment.bounds = (CGRect){CGPointZero, fittingSize};
      [attributedText addAttribute:NSAttachmentAttributeName value:attachment range:range];
    }
  ];

  [attributedText endEditing];

  return [attributedText copy];
}

- (NSTextStorage *)textStorageAndLayoutManagerThatFitsSize:(CGSize)size
                                        exclusiveOwnership:(BOOL)exclusiveOwnership
{
  NSValue *key = [NSValue valueWithCGSize:size];
  NSTextStorage *cachedTextStorage = [_cachedTextStorages objectForKey:key];

  if (cachedTextStorage) {
    if (exclusiveOwnership) {
      [_cachedTextStorages removeObjectForKey:key];
    }

    return cachedTextStorage;
  }

  NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:size];

  textContainer.lineFragmentPadding = 0.0; // Note, the default value is 5.
  textContainer.lineBreakMode =
    _maximumNumberOfLines > 0 ? _lineBreakMode : NSLineBreakByClipping;
  textContainer.maximumNumberOfLines = _maximumNumberOfLines;

  NSLayoutManager *layoutManager = [NSLayoutManager new];
  [layoutManager addTextContainer:textContainer];

  NSTextStorage *textStorage =
    [[NSTextStorage alloc] initWithAttributedString:[self attributedTextWithMeasuredAttachmentsThatFitSize:size]];

  [self postprocessAttributedText:textStorage];

  [textStorage addLayoutManager:layoutManager];

  if (_adjustsFontSizeToFit) {
    CGFloat minimumFontSize =
      MAX(_minimumFontScale * (self.textAttributes.effectiveFont.pointSize), 4.0);
    [textStorage scaleFontSizeToFitSize:size
                        minimumFontSize:minimumFontSize
                        maximumFontSize:self.textAttributes.effectiveFont.pointSize];
  }

  if (!exclusiveOwnership) {
    [_cachedTextStorages setObject:textStorage forKey:key];
  }

  return textStorage;
}

- (void)layoutWithMetrics:(RCTLayoutMetrics)layoutMetrics
            layoutContext:(RCTLayoutContext)layoutContext
{
  // If the view got new `contentFrame`, we have to redraw it because
  // and sizes of embedded views may change.
  if (!CGRectEqualToRect(self.layoutMetrics.contentFrame, layoutMetrics.contentFrame)) {
    _needsUpdateView = YES;
  }

  if (self.textAttributes.layoutDirection != layoutMetrics.layoutDirection) {
    self.textAttributes.layoutDirection = layoutMetrics.layoutDirection;
    [self invalidateCache];
  }

  [super layoutWithMetrics:layoutMetrics layoutContext:layoutContext];
}

- (void)layoutSubviewsWithContext:(RCTLayoutContext)layoutContext
{
  NSTextStorage *textStorage =
    [self textStorageAndLayoutManagerThatFitsSize:self.availableSize
                               exclusiveOwnership:NO];
  NSLayoutManager *layoutManager = textStorage.layoutManagers.firstObject;
  NSTextContainer *textContainer = layoutManager.textContainers.firstObject;
  NSRange glyphRange = [layoutManager glyphRangeForTextContainer:textContainer];
  NSRange characterRange = [layoutManager characterRangeForGlyphRange:glyphRange
                                                     actualGlyphRange:NULL];

  [textStorage enumerateAttribute:RCTBaseTextShadowViewEmbeddedShadowViewAttributeName
                          inRange:characterRange
                          options:0
                       usingBlock:
    ^(RCTShadowView *shadowView, NSRange range, BOOL *stop) {
      if (!shadowView) {
        return;
      }

      CGRect glyphRect = [layoutManager boundingRectForGlyphRange:range
                                                  inTextContainer:textContainer];

      NSTextAttachment *attachment =
        [textStorage attribute:NSAttachmentAttributeName atIndex:range.location effectiveRange:nil];

      CGSize attachmentSize = attachment.bounds.size;

      UIFont *font = [textStorage attribute:NSFontAttributeName atIndex:range.location effectiveRange:nil];

      CGRect frame = {{
        RCTRoundPixelValue(glyphRect.origin.x),
        RCTRoundPixelValue(glyphRect.origin.y + glyphRect.size.height - attachmentSize.height + font.descender)
      }, {
        RCTRoundPixelValue(attachmentSize.width),
        RCTRoundPixelValue(attachmentSize.height)
      }};
      
      NSRange truncatedGlyphRange = [layoutManager truncatedGlyphRangeInLineFragmentForGlyphAtIndex:range.location];
      BOOL viewIsTruncated = NSIntersectionRange(range, truncatedGlyphRange).length != 0;

      RCTLayoutContext localLayoutContext = layoutContext;
      localLayoutContext.absolutePosition.x += frame.origin.x;
      localLayoutContext.absolutePosition.y += frame.origin.y;

      [shadowView layoutWithMinimumSize:frame.size
                            maximumSize:frame.size
                        layoutDirection:self.layoutMetrics.layoutDirection
                          layoutContext:localLayoutContext];

      RCTLayoutMetrics localLayoutMetrics = shadowView.layoutMetrics;
      localLayoutMetrics.frame.origin = frame.origin; // Reinforcing a proper frame origin for the Shadow View.
      if (viewIsTruncated) {
        localLayoutMetrics.displayType = RCTDisplayTypeNone;
      }
      [shadowView layoutWithMetrics:localLayoutMetrics layoutContext:localLayoutContext];
    }
  ];


  if (_onTextLayout) {
    NSMutableArray *lineData = [NSMutableArray new];
    [layoutManager
     enumerateLineFragmentsForGlyphRange:glyphRange
     usingBlock:^(CGRect overallRect, CGRect usedRect, NSTextContainer * _Nonnull usedTextContainer, NSRange lineGlyphRange, BOOL * _Nonnull stop) {
       NSRange range = [layoutManager characterRangeForGlyphRange:lineGlyphRange actualGlyphRange:nil];
       NSString *renderedString = [textStorage.string substringWithRange:range];
       UIFont *font = [[textStorage attributedSubstringFromRange:range] attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
       [lineData addObject:
        @{
          @"text": renderedString,
          @"x": @(usedRect.origin.x),
          @"y": @(usedRect.origin.y),
          @"width": @(usedRect.size.width),
          @"height": @(usedRect.size.height),
          @"descender": @(-font.descender),
          @"capHeight": @(font.capHeight),
          @"ascender": @(font.ascender),
          @"xHeight": @(font.xHeight),
          }];
     }];
    NSDictionary *payload =
    @{
      @"lines": lineData,
      };
    _onTextLayout(payload);
  }
}

- (CGFloat)lastBaselineForSize:(CGSize)size
{
  NSAttributedString *attributedText =
    [self textStorageAndLayoutManagerThatFitsSize:size exclusiveOwnership:NO];

  __block CGFloat maximumDescender = 0.0;

  [attributedText enumerateAttribute:NSFontAttributeName
                             inRange:NSMakeRange(0, attributedText.length)
                             options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
                          usingBlock:
    ^(UIFont *font, NSRange range, __unused BOOL *stop) {
      if (maximumDescender > font.descender) {
        maximumDescender = font.descender;
      }
    }
  ];

  return size.height + maximumDescender;
}

static YGSize RCTTextShadowViewMeasure(YGNodeRef node, float width, YGMeasureMode widthMode, float height, YGMeasureMode heightMode)
{
  CGSize maximumSize = (CGSize){
    widthMode == YGMeasureModeUndefined ? CGFLOAT_MAX : RCTCoreGraphicsFloatFromYogaFloat(width),
    heightMode == YGMeasureModeUndefined ? CGFLOAT_MAX : RCTCoreGraphicsFloatFromYogaFloat(height),
  };

  RCTTextShadowView *shadowTextView = (__bridge RCTTextShadowView *)YGNodeGetContext(node);

  NSTextStorage *textStorage =
    [shadowTextView textStorageAndLayoutManagerThatFitsSize:maximumSize
                                         exclusiveOwnership:NO];

  NSLayoutManager *layoutManager = textStorage.layoutManagers.firstObject;
  NSTextContainer *textContainer = layoutManager.textContainers.firstObject;
  [layoutManager ensureLayoutForTextContainer:textContainer];
  CGSize size = [layoutManager usedRectForTextContainer:textContainer].size;

  CGFloat letterSpacing = shadowTextView.textAttributes.letterSpacing;
  if (!isnan(letterSpacing) && letterSpacing < 0) {
    size.width -= letterSpacing;
  }

  size = (CGSize){
    MIN(RCTCeilPixelValue(size.width), maximumSize.width),
    MIN(RCTCeilPixelValue(size.height), maximumSize.height)
  };

  // Adding epsilon value illuminates problems with converting values from
  // `double` to `float`, and then rounding them to pixel grid in Yoga.
  CGFloat epsilon = 0.001;
  return (YGSize){
    RCTYogaFloatFromCoreGraphicsFloat(size.width + epsilon),
    RCTYogaFloatFromCoreGraphicsFloat(size.height + epsilon)
  };
}

static float RCTTextShadowViewBaseline(YGNodeRef node, const float width, const float height)
{
  RCTTextShadowView *shadowTextView = (__bridge RCTTextShadowView *)YGNodeGetContext(node);

  CGSize size = (CGSize){
    RCTCoreGraphicsFloatFromYogaFloat(width),
    RCTCoreGraphicsFloatFromYogaFloat(height)
  };

  CGFloat lastBaseline = [shadowTextView lastBaselineForSize:size];

  return RCTYogaFloatFromCoreGraphicsFloat(lastBaseline);
}

@end
