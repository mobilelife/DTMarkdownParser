//
//  DTMarkdownParser.m
//  DTMarkdownParser
//
//  Created by Oliver Drobnik on 18.10.13.
//  Copyright (c) 2013 Cocoanetics. All rights reserved.
//

#import "DTMarkdownParser.h"
#import "NSScanner+DTMarkdown.h"

#import <tgmath.h>

// constants for special lines
NSString * const DTMarkdownParserSpecialTagH1 = @"H1";
NSString * const DTMarkdownParserSpecialTagH2 = @"H2";
NSString * const DTMarkdownParserSpecialTagHeading = @"<HEADING>";
NSString * const DTMarkdownParserSpecialTagHR = @"HR";
NSString * const DTMarkdownParserSpecialTagPre = @"PRE";
NSString * const DTMarkdownParserSpecialFencedPreStart = @"<FENCED BEGIN>";
NSString * const DTMarkdownParserSpecialFencedPreCode = @"<FENCED CODE>";
NSString * const DTMarkdownParserSpecialFencedPreEnd = @"<FENCED END>";
NSString * const DTMarkdownParserSpecialList = @"<LIST>";
NSString * const DTMarkdownParserSpecialSubList = @"<SUBLIST>";

@implementation DTMarkdownParser
{
	NSString *_string;
	DTMarkdownParserOptions _options;
	
	// lookup bitmask what delegate methods are implemented
	struct
	{
		unsigned int supportsStartDocument:1;
		unsigned int supportsEndDocument:1;
		unsigned int supportsFoundCharacters:1;
		unsigned int supportsStartTag:1;
		unsigned int supportsEndTag:1;
	} _delegateFlags;
	
	// parsing state
	NSMutableArray *_tagStack;
	
	// lookup dictionary for special lines
	NSMutableDictionary *_specialLines;
	NSMutableIndexSet *_ignoredLines;
	NSMutableDictionary *_references;
	NSMutableDictionary *_lineIndentLevel;
	NSMutableArray *_lineRanges;
	NSMutableArray *_paragraphRanges;
	
	NSDataDetector *_dataDetector;
}

- (instancetype)initWithString:(NSString *)string options:(DTMarkdownParserOptions)options
{
	self = [super init];
	
	if (self)
	{
		_string = [string copy];
		_options = options;
		
		// default detector
		_dataDetector = [NSDataDetector dataDetectorWithTypes:(NSTextCheckingTypes)NSTextCheckingTypeLink error:NULL];
	}
	
	return self;
}

#pragma mark - Communication with Delegate

- (void)_reportBeginOfTag:(NSString *)tag attributes:(NSDictionary *)attributes
{
	if (_delegateFlags.supportsStartTag)
	{
		[_delegate parser:self didStartElement:tag attributes:attributes];
	}
}

- (void)_reportEndOfTag:(NSString *)tag
{
	if (_delegateFlags.supportsStartTag)
	{
		[_delegate parser:self didEndElement:tag];
	}
}

- (void)_reportCharacters:(NSString *)string
{
	if (_delegateFlags.supportsFoundCharacters)
	{
		[_delegate parser:self foundCharacters:string];
	}
}

#pragma mark - Parsing Helpers

- (void)_pushTag:(NSString *)tag attributes:(NSDictionary *)attributes
{
	[_tagStack addObject:tag];
	[self _reportBeginOfTag:tag attributes:attributes];
}

- (void)_popTag
{
	NSString *tag = [self _currentTag];
	
	[self _reportEndOfTag:tag];
	[_tagStack removeLastObject];
}

- (NSString *)_currentTag
{
	return [_tagStack lastObject];
}

- (void)_processMarkedString:(NSString *)markedString insideMarker:(NSString *)marker
{
	NSAssert([markedString hasPrefix:marker] && [markedString hasSuffix:marker], @"Processed string has to have the marker at beginning and end");
	
	NSUInteger markerLength = [marker length];
	NSRange insideMarkedRange = NSMakeRange(markerLength, markedString.length - 2*markerLength);
	
	// trim off prefix and suffix marker
	markedString = [markedString substringWithRange:insideMarkedRange];
	
	BOOL processFurtherMarkers = YES;
	
	// open the tag for this marker
	if ([marker isEqualToString:@"*"] || [marker isEqualToString:@"_"])
	{
		[self _pushTag:@"em" attributes:nil];
	}
	else if ([marker isEqualToString:@"**"] || [marker isEqualToString:@"__"])
	{
		[self _pushTag:@"strong" attributes:nil];
	}
	else if ([marker isEqualToString:@"~~"])
	{
		[self _pushTag:@"del" attributes:nil];
	}
	else if ([marker isEqualToString:@"`"])
	{
		[self _pushTag:@"code" attributes:nil];
		processFurtherMarkers = NO;
	}
	
	if (processFurtherMarkers)
	{
		NSScanner *scanner = [NSScanner scannerWithString:markedString];
		scanner.charactersToBeSkipped = nil;
		
		NSString *furtherMarker;
		
		if ([scanner scanMarkdownBeginMarker:&furtherMarker] && [markedString hasSuffix:furtherMarker])
		{
			[self _processMarkedString:markedString insideMarker:furtherMarker];
		}
		else
		{
			[self _reportCharacters:markedString];
		}
	}
	else
	{
		[self _reportCharacters:markedString];
	}
	
	// close the tag for this marker
	[self _popTag];
}

- (void)_processCharacters:(NSString *)string allowAutodetection:(BOOL)allowAutodetection
{
	if (!allowAutodetection || !_dataDetector)
	{
		[self _reportCharacters:string];
		return;
	}
	
	NSArray *matches = [_dataDetector matchesInString:string options:0 range:NSMakeRange(0, [string length])];
	
	NSUInteger outputChars = 0;
	
	for (NSTextCheckingResult *match in matches)
	{
		if (match.range.location > outputChars)
		{
			// need to output part before match
			NSString *substring = [string substringWithRange:NSMakeRange(outputChars, match.range.location - outputChars)];
			[self _reportCharacters:substring];
		}
		
		NSString *urlString = [string substringWithRange:match.range];
		
		// get URL from match if possible
		NSURL *URL = [match URL];
		
#if TARGET_OS_IPHONE
		if ([[URL scheme] isEqualToString:@"tel"])
		{
			// output as is
			NSString *substring = [string substringWithRange:match.range];
			[self _reportCharacters:substring];
		}
		else
#endif
		{
			NSDictionary *attributes = @{@"href": [URL absoluteString]};
			[self _pushTag:@"a" attributes:attributes];
			[self _reportCharacters:urlString];
			[self _popTag];
		}
		
		outputChars = NSMaxRange(match.range);
	}
	
	// output reset after last hyperlink
	NSRange restRange = NSMakeRange(outputChars, [string length] - outputChars);
	
	if (restRange.length>0)
	{
		// need to output part before match
		NSString *substring = [string substringWithRange:restRange];
		[self _reportCharacters:substring];
	}
}

- (void)_processLine:(NSString *)line withIndex:(NSUInteger)lineIndex allowAutoDetection:(BOOL)allowAutoDetection
{
	BOOL hasNewline = NO;
	BOOL needsBR = NO;
	BOOL allowLineBreak = [self _shouldAllowLineBreakAfterLineAtIndex:lineIndex];
	
	if (allowLineBreak)
	{
		line = [line stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
		
		if ([line hasSuffix:@"\n"] && (_options && DTMarkdownParserOptionGitHubLineBreaks))
		{
			line = [line substringToIndex:[line length]-1];
			needsBR = YES;
			
		}
		else if ([line hasSuffix:@"  \n"])
		{
			needsBR = YES;
			
			line = [line substringToIndex:[line length]-3];
		}
	}
	else
	{
		if ([line hasSuffix:@"\n"])
		{
			hasNewline = YES;
			line = [line substringToIndex:[line length]-1];
		}
		
		if ([line hasSuffix:@"\r"])
		{
			line = [line substringToIndex:[line length]-1];
		}
	}
	
	NSScanner *scanner = [NSScanner scannerWithString:line];
	scanner.charactersToBeSkipped = nil;

	// ingore leading whitespace characters for non PRE
	if (!_specialLines[@(lineIndex)])
	{
		[scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
	}
	
	NSCharacterSet *specialChars = [NSCharacterSet characterSetWithCharactersInString:@"*_~[!`<"];
	
	while (![scanner isAtEnd])
	{
		NSString *part;
		
		// scan part until next special character
		if ([scanner scanUpToCharactersFromSet:specialChars intoString:&part])
		{
			// output part before markers
			[self _processCharacters:part allowAutodetection:allowAutoDetection];
			
			// re-enable detection, this might have been a faulty string containing a href
			allowAutoDetection = YES;
		}
		
		// stop scanning if done
		if ([scanner isAtEnd])
		{
			break;
		}
		
		// scan marker
		NSString *effectiveOpeningMarker;
		
		NSRange markedRange = NSMakeRange(scanner.scanLocation, 0);
		
		NSDictionary *linkAttributes;
		NSString *enclosedString;
		
		if ([scanner scanMarkdownImageAttributes:&linkAttributes references:_references])
		{
			[self _pushTag:@"img" attributes:linkAttributes];
			[self _popTag];
		}
		else if ([scanner scanMarkdownHyperlinkAttributes:&linkAttributes enclosedString:&enclosedString references:_references])
		{
			[self _pushTag:@"a" attributes:linkAttributes];
			
			// might contain further markdown/images
			[self _processLine:enclosedString withIndex:lineIndex allowAutoDetection:NO];
			
			[self _popTag];
		}
		else if ([scanner scanMarkdownBeginMarker:&effectiveOpeningMarker])
		{
			NSString *enclosedPart;
			
			if ([scanner scanUpToString:effectiveOpeningMarker intoString:&enclosedPart])
			{
				// there has to be a closing marker as well
				if ([scanner scanString:effectiveOpeningMarker intoString:NULL])
				{
					markedRange.length = scanner.scanLocation - markedRange.location;
					NSString *markedString = [line substringWithRange:markedRange];
					
					[self _processMarkedString:markedString insideMarker:effectiveOpeningMarker];
				}
				else
				{
					// output as is, not enclosed
					NSString *joined = [effectiveOpeningMarker stringByAppendingString:enclosedPart];
					
					[self _reportCharacters:joined];
				}
			}
			else
			{
				// did not enclose anything
				[self _reportCharacters:effectiveOpeningMarker];
				scanner.scanLocation = markedRange.location + [effectiveOpeningMarker length];
			}
		}
		else
		{
			// single special character, just output
			NSString *specialChar = [scanner.string substringWithRange:NSMakeRange(scanner.scanLocation, 1)];
			
			[self _reportCharacters:specialChar];
			scanner.scanLocation ++;
			
			// scan part until next special character
			if ([scanner scanUpToCharactersFromSet:specialChars intoString:&part])
			{
				// output part before markers
				[self _processCharacters:part allowAutodetection:NO];
			}
		}
	}
	
	if (needsBR)
	{
		[self _pushTag:@"br" attributes:nil];
		[self _popTag];
	}
}

- (NSUInteger)_numberOfLeadingSpacesForLine:(NSString *)line
{
	NSUInteger spacesCount = 0;
	
	for (NSUInteger idx=0; idx < [line length]; idx++)
	{
		unichar ch = [line characterAtIndex:idx];
		
		if (ch == ' ')
		{
			spacesCount++;
		}
		else if (ch == '\t')
		{
			spacesCount+=4;
		}
		else
		{
			break;
		}
	}
	
	return spacesCount;
}

- (BOOL)_shouldCloseListItemAfterLineAtIndex:(NSUInteger)lineIndex
{
	NSString *specialTypeOfFollowingLine = _specialLines[@(lineIndex+1)];

	// following line is a sub list, indent does not matter because we deal with opening/closing separately
	if (specialTypeOfFollowingLine == DTMarkdownParserSpecialSubList)
	{
		return NO;
	}

	// normal paragraph follows
	if (!specialTypeOfFollowingLine && ![_ignoredLines containsIndex:lineIndex+1])
	{
		return NO;
	}

	return YES;
}

- (BOOL)_shouldAllowLineBreakAfterLineAtIndex:(NSUInteger)lineIndex
{
	NSRange lineRange = [_lineRanges[lineIndex] rangeValue];
	NSRange paragraphRange = [self _rangeOfParagraphAtIndex:lineRange.location];
	
	BOOL lineIsLastInParagraph = (NSMaxRange(lineRange) == NSMaxRange(paragraphRange));
	
	if (lineIsLastInParagraph)
	{
		return NO;
	}
	
	NSString *specialLineTypeOfFollowingLine = _specialLines[@(lineIndex+1)];
	
	if (![_ignoredLines containsIndex:lineIndex+1] && !specialLineTypeOfFollowingLine)
	{
		return YES;
	}
	
	return NO;
}

- (void)_processListLineAtLineIndex:(NSUInteger)lineIndex
{
	NSRange lineRange = [self _rangeOfLineAtLineIndex:lineIndex];
	NSString *line = [_string substringWithRange:lineRange];
	
	NSString *prefix;
	
	NSString *specialTypeOfLine = _specialLines[@(lineIndex)];
	
	NSInteger previousLineIndent = lineIndex?[_lineIndentLevel[@(lineIndex-1)] integerValue]:0;
	NSInteger currentLineIndent = [_lineIndentLevel[@(lineIndex)] integerValue];
	
	previousLineIndent = floor(previousLineIndent/4.0);
	currentLineIndent = floor(currentLineIndent/4.0);
	
	if (specialTypeOfLine == DTMarkdownParserSpecialSubList)
	{
		// we know there is a list prefix, but we need to eliminate the indentation first
		line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	}
	
	NSScanner *scanner = [NSScanner scannerWithString:line];
	scanner.charactersToBeSkipped = nil;
	
	[scanner scanMarkdownLineListPrefix:&prefix];
	
	NSAssert(prefix, @"Cannot process line, no list prefix");
	
	NSAssert(![[self _currentTag] isEqualToString:@"p"], @"There should never be an open P tag in %s", __PRETTY_FUNCTION__);
	
	// cut off prefix
	line = [line substringFromIndex:scanner.scanLocation];
	
	
	BOOL needOpenNewListLevel = NO;
	
	if (specialTypeOfLine == DTMarkdownParserSpecialList)
	{
		if (![_tagStack containsObject:@"ul"] && ![_tagStack containsObject:@"ol"])
		{
			// first line of list opens only if no list present
			needOpenNewListLevel = YES;
		}
	}
	else if (specialTypeOfLine == DTMarkdownParserSpecialSubList)
	{
		// sub list only opens one level
		
		if (currentLineIndent>previousLineIndent)
		{
			needOpenNewListLevel = YES;
		}
	}
	
	if (currentLineIndent<previousLineIndent)
	{
		NSInteger level = previousLineIndent;
		
		// close any number of list levels
		while (level>currentLineIndent)
		{
			NSString *tagToPop = [self _currentTag];
			
			[self _popTag];
			
			if ([tagToPop isEqualToString:@"ul"] || [tagToPop isEqualToString:@"ol"])
			{
				level--;
			}
		}
	}
	
	
	if (needOpenNewListLevel)
	{
		// need to open list
		if ([prefix hasSuffix:@"."])
		{
			// ordered list
			[self _pushTag:@"ol" attributes:nil];
		}
		else
		{
			// unordered list
			[self _pushTag:@"ul" attributes:nil];
		}
	}
	
	if ([[self _currentTag] isEqualToString:@"li"])
	{
		[self _popTag]; // previous li
	}
	
	[self _pushTag:@"li" attributes:nil];
	
	BOOL hasHangingParagraphs = [self _hasHangingParagraphsForListItemBeginningAtLineIndex:lineIndex];
	
	if (hasHangingParagraphs)
	{
		[self _pushTag:@"p" attributes:nil];
	}
	
	// process line as normal without prefix
	[self _processLine:line withIndex:lineIndex allowAutoDetection:YES];
	
	if (hasHangingParagraphs)
	{
		return;
	}
	
	if ([self _shouldCloseListItemAfterLineAtIndex:lineIndex])
	{
		if ([[self _currentTag] isEqualToString:@"p"])
		{
			[self _popTag];
		}
		
		[self _popTag]; // li
		
		if ([_ignoredLines containsIndex:lineIndex+1])
		{
			[self _popTag];
		}
	}
}

- (void)_findAndMarkSpecialLines
{
	_ignoredLines = [NSMutableIndexSet new];
	_specialLines = [NSMutableDictionary new];
	_references = [NSMutableDictionary new];
	_lineIndentLevel = [NSMutableDictionary new];
	_lineRanges = [NSMutableArray new];
	_paragraphRanges = [NSMutableArray new];
	
	NSScanner *scanner = [NSScanner scannerWithString:_string];
	scanner.charactersToBeSkipped = nil;
	
	NSUInteger lineIndex = 0;
	NSInteger previousLineIndent = 0;
	
	NSRange paragraphRange = NSMakeRange(0, 0);
	
	while (![scanner isAtEnd])
	{
		NSString *line;
		
		NSRange lineRange = NSMakeRange(scanner.scanLocation, 0);
		
		if ([scanner scanUpToString:@"\n" intoString:&line])
		{
			lineRange.length = scanner.scanLocation - lineRange.location;
			paragraphRange = NSUnionRange(paragraphRange, lineRange);
			
			BOOL didFindSpecial = NO;
			NSString *specialOfLineBefore = nil;
			
			NSInteger currentLineIndent = [self _numberOfLeadingSpacesForLine:line];
			_lineIndentLevel[@(lineIndex)] = @(currentLineIndent);
			
			if (lineIndex)
			{
				specialOfLineBefore = _specialLines[@(lineIndex-1)];
				
				unichar firstChar = [line characterAtIndex:0];
				
				if (firstChar=='-' || firstChar=='=')
				{
					line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
					NSUInteger lineLen = [line length];
					
					NSUInteger idx=0;
					while (idx<lineLen && [line characterAtIndex:idx] == firstChar)
					{
						idx++;
					}
					
					if (idx>=lineLen)
					{
						if (![_ignoredLines containsIndex:lineIndex-1])
						{
							// full line is this character
							[_ignoredLines addIndex:lineIndex];
							
							if (firstChar=='=')
							{
								_specialLines[@(lineIndex-1)] = DTMarkdownParserSpecialTagH1;
								didFindSpecial = YES;
							}
							else if (firstChar=='-')
							{
								_specialLines[@(lineIndex-1)] = DTMarkdownParserSpecialTagH2;
								didFindSpecial = YES;
							}
						}
					}
				}
			}
			
			if (!didFindSpecial)
			{
				NSCharacterSet *ruleCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@" -*_\n"];
				
				if ([[line stringByTrimmingCharactersInSet:ruleCharacterSet] length]==0)
				{
					if ([[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] rangeOfString:@"   "].location == NSNotFound)
					{
						_specialLines[@(lineIndex)] = DTMarkdownParserSpecialTagHR;
					}
					
					// block it from further special detection
					didFindSpecial = YES;
				}
			}
			
			// look for lines with references
			if (!didFindSpecial)
			{
				NSString *ref;
				NSString *link;
				NSString *title;
				
				NSScanner *lineScanner = [NSScanner scannerWithString:line];
				lineScanner.charactersToBeSkipped = nil;
				
				if ([lineScanner scanMarkdownHyperlinkReferenceLine:&ref URLString:&link title:&title])
				{
					NSMutableDictionary *tmpDict = [NSMutableDictionary dictionary];
					
					if (link)
					{
						[tmpDict setObject:link forKey:@"href"];
					}
					
					if (title)
					{
						[tmpDict setObject:title forKey:@"title"];
					}
					
					[_references setObject:tmpDict forKey:ref];
					
					[_ignoredLines addIndex:lineIndex];
					didFindSpecial = YES;
				}
			}
			
			// look for indented pre lines
			if (!didFindSpecial && ([line hasPrefix:@"\t" ] || [line hasPrefix:@"    "]))
			{
				// PRE only possible if there is an empty line before it or already a PRE, or beginning doc
				
				if (!lineIndex || (lineIndex>0 && (specialOfLineBefore == DTMarkdownParserSpecialTagPre || [_ignoredLines containsIndex:lineIndex-1])))
				{
					_specialLines[@(lineIndex)] = DTMarkdownParserSpecialTagPre;
					didFindSpecial = YES;
				}
			}
			
			if (!didFindSpecial && [line hasPrefix:@"```"])
			{
				if (specialOfLineBefore == DTMarkdownParserSpecialFencedPreCode || specialOfLineBefore == DTMarkdownParserSpecialFencedPreStart)
				{
					_specialLines[@(lineIndex)] = DTMarkdownParserSpecialFencedPreEnd;
					[_ignoredLines addIndex:lineIndex];
				}
				else
				{
					_specialLines[@(lineIndex)] = DTMarkdownParserSpecialFencedPreStart;
					[_ignoredLines addIndex:lineIndex];
				}
				
				didFindSpecial = YES;
			}
			
			if (!didFindSpecial)
			{
				if (specialOfLineBefore == DTMarkdownParserSpecialFencedPreCode || specialOfLineBefore == DTMarkdownParserSpecialFencedPreStart)
				{
					_specialLines[@(lineIndex)] = DTMarkdownParserSpecialFencedPreCode;
				}
			}
			
			if (!didFindSpecial)
			{
				if ([line hasPrefix:@"#"])
				{
					_specialLines[@(lineIndex)] = DTMarkdownParserSpecialTagHeading;
					
					didFindSpecial = YES;
				}
			}
			
			if (!didFindSpecial)
			{
				NSScanner *lineScanner = [NSScanner scannerWithString:line];
				lineScanner.charactersToBeSkipped = nil;
				
				NSString *listPrefix;
				if ([lineScanner scanMarkdownLineListPrefix:&listPrefix])
				{
					_specialLines[@(lineIndex)] = DTMarkdownParserSpecialList;
					didFindSpecial = YES;
				}
				else if (specialOfLineBefore == DTMarkdownParserSpecialList || specialOfLineBefore == DTMarkdownParserSpecialSubList)
				{
					// line before ist list start
					if ((currentLineIndent>=previousLineIndent+4 && currentLineIndent<=previousLineIndent+8) || (currentLineIndent>=previousLineIndent-4 && currentLineIndent<=previousLineIndent))
					{
						NSString *indentedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
						
						NSScanner *indentedScanner = [NSScanner scannerWithString:indentedLine];
						indentedScanner.charactersToBeSkipped = nil;
						
						if ([indentedScanner scanMarkdownLineListPrefix:&listPrefix])
						{
							_specialLines[@(lineIndex)] = DTMarkdownParserSpecialSubList;
							didFindSpecial = YES;
						}
					}
				}
			}
			
			previousLineIndent = currentLineIndent;
		}
		
		// look for empty lines
		if (![[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length])
		{
			[_ignoredLines addIndex:lineIndex];
		}
		
		if ([scanner scanString:@"\n" intoString:NULL])
		{
			lineRange.length++;
		}
		
		paragraphRange = NSUnionRange(paragraphRange, lineRange);
		
		BOOL currentLineIsIgnored = [_ignoredLines containsIndex:lineIndex];
		BOOL currentLineIsHR = _specialLines[@(lineIndex)] == DTMarkdownParserSpecialTagHR || _specialLines[@(lineIndex)] == DTMarkdownParserSpecialTagHeading;
		BOOL currentLineBeginsList = (_specialLines[@(lineIndex)] == DTMarkdownParserSpecialList);

		if (currentLineIsIgnored || [scanner isAtEnd] || currentLineIsHR || currentLineBeginsList)
		{
			NSRange netParagraphRange = paragraphRange;
			
			if (currentLineIsIgnored || currentLineIsHR || currentLineBeginsList)
			{
				netParagraphRange.length -= lineRange.length;
			}

			if (netParagraphRange.length)
			{
				[_paragraphRanges addObject:[NSValue valueWithRange:netParagraphRange]];
			}

			if (currentLineIsIgnored || currentLineIsHR)
			{
				[_paragraphRanges addObject:[NSValue valueWithRange:lineRange]];
				paragraphRange = NSMakeRange(paragraphRange.location + paragraphRange.length, 0);
			}
			else
			{
				paragraphRange = lineRange;
			}
		}
		
		[_lineRanges addObject:[NSValue valueWithRange:lineRange]];
		
		lineIndex++;
	}
}


- (NSRange)_rangeOfParagraphAtIndex:(NSUInteger)index
{
	for (NSValue *value in _paragraphRanges)
	{
		NSRange range = [value rangeValue];
		
		if (NSLocationInRange(index, range))
		{
			return range;
		}
	}
	
	return NSMakeRange(NSNotFound, 0);
}

- (NSRange)_rangeOfLineAtLineIndex:(NSUInteger)lineIndex
{
	NSValue *value = _lineRanges[lineIndex];
	
	return [value rangeValue];
}


- (BOOL)_hasHangingParagraphsForListItemBeginningAtLineIndex:(NSUInteger)lineIndex
{
	NSRange lineRange = [self _rangeOfLineAtLineIndex:lineIndex];
	NSUInteger numberOfLines = [_lineRanges count];
	NSUInteger numberIgnored = 0;
	
	while (lineIndex<(numberOfLines-1))
	{
		lineIndex++;
		
		if ([_ignoredLines containsIndex:lineIndex])
		{
			numberIgnored ++;
			continue;
		}
		
		// only normal paragraphs can be hanging
		if (_specialLines[@(lineIndex)])
		{
			return NO;
		}
		
		lineRange = [self _rangeOfLineAtLineIndex:lineIndex];
		NSString *line = [_string substringWithRange:lineRange];
		
		NSUInteger leadingSpaces = [self _numberOfLeadingSpacesForLine:line];
		
		if (leadingSpaces>0 && numberIgnored>0)
		{
			return YES;
		}
		
		return NO;
	}
	
	return NO;
}



#pragma mark - Parsing

- (BOOL)parse
{
	if (![_string length])
	{
		return NO;
	}
	
	_tagStack = [NSMutableArray new];
	
	if (_delegateFlags.supportsStartDocument)
	{
		[_delegate parserDidStartDocument:self];
	}
	
	[self _findAndMarkSpecialLines];
	
	// enumerate lines
	[_lineRanges enumerateObjectsUsingBlock:^(NSValue *rangeValue, NSUInteger lineIndex, BOOL *stop) {
		
		if ([_ignoredLines containsIndex:lineIndex])
		{
			return;
		}
		
		NSRange lineRange = [rangeValue rangeValue];
		NSRange paragraphRange = [self _rangeOfParagraphAtIndex:lineRange.location];
		
		if (lineRange.length)
		{
			NSString *line = [_string substringWithRange:lineRange];
			
			NSString *specialLine = _specialLines[@(lineIndex)];
			NSString *specialFollowingLine = _specialLines[@(lineIndex+1)];
			BOOL followingLineIsIgnored = [_ignoredLines containsIndex:lineIndex+1];
			BOOL lineIsLastInParagraph = NO;
			
			if (NSMaxRange(lineRange) == NSMaxRange(paragraphRange))
			{
				lineIsLastInParagraph = YES;
			}
			
			BOOL lineIsFirstInParagraph = NO;
			
			if (lineRange.location == paragraphRange.location)
			{
				lineIsFirstInParagraph = YES;
			}
			
			BOOL needsPushTag = lineIsFirstInParagraph; // first line usually pushes new paragraph
			NSString *tag = @"p";
			NSUInteger headerLevel = 0;
			
			if (specialLine == DTMarkdownParserSpecialTagHR)
			{
				[self _pushTag:@"hr" attributes:nil];
				[self _popTag];
				
				return;
			}
			else if (specialLine == DTMarkdownParserSpecialList || specialLine == DTMarkdownParserSpecialSubList)
			{
				[self _processListLineAtLineIndex:lineIndex];
				
				return;
			}
			else if (specialLine == DTMarkdownParserSpecialTagPre || specialLine == DTMarkdownParserSpecialFencedPreCode)
			{
				NSString *codeLine;
				
				if (specialLine == DTMarkdownParserSpecialTagPre)
				{
					// trim off indenting
					if ([line hasPrefix:@"\t"])
					{
						codeLine = [line substringFromIndex:1];
					}
					else if ([line hasPrefix:@"    "])
					{
						codeLine = [line substringFromIndex:4];
					}
				}
				else
				{
					codeLine = line;
				}
				
				if (![[self _currentTag] isEqualToString:@"code"])
				{
					[self _pushTag:@"pre" attributes:nil];
					[self _pushTag:@"code" attributes:nil];
				}
				
				[self _reportCharacters:codeLine];
				
				if (lineIsLastInParagraph)
				{
					[self _popTag];
					[self _popTag];
				}
				
				return;
			}
			else  if ([line hasPrefix:@">"])
			{
				tag = @"blockquote";
				
				if (![[self _currentTag] isEqualToString:@"blockquote"])
				{
					needsPushTag = YES;
				}
			}
			else if (specialLine == DTMarkdownParserSpecialTagHeading)
			{
				while ([line hasPrefix:@"#"])
				{
					headerLevel++;
					
					line = [line substringFromIndex:1];
				}
				
				// trim off leading spaces
				while ([line hasPrefix:@" "])
				{
					line = [line substringFromIndex:1];
				}
				
				// trim off trailing hashes
				while ([line hasSuffix:@"#"] || [line hasSuffix:@"#\n"])
				{
					line = [line substringToIndex:[line length]-1];
				}
				
				// trim off trailing spaces
				while ([line hasSuffix:@" "])
				{
					line = [line substringToIndex:[line length]-1];
				}
			}
			
			if (specialLine == DTMarkdownParserSpecialTagH1)
			{
				headerLevel = 1;
			}
			else if (specialLine == DTMarkdownParserSpecialTagH2)
			{
				headerLevel = 2;
			}
			
			if (headerLevel)
			{
				tag = [NSString stringWithFormat:@"h%d", (int)headerLevel];
			}
			
			BOOL willCloseTag = (lineIsLastInParagraph || headerLevel || followingLineIsIgnored || specialFollowingLine == DTMarkdownParserSpecialList || specialFollowingLine == DTMarkdownParserSpecialTagHR);
			
			if (needsPushTag)
			{
				// if there is still an open p we need to go back far enough to close it
				while ([_tagStack containsObject:@"p"])
				{
					[self _popTag];
				}
				
				[self _pushTag:tag attributes:nil];
			}
			
			if ([tag isEqualToString:@"blockquote"])
			{
				if ([line hasPrefix:@">"])
				{
					line = [line substringFromIndex:1];
				}
				
				if ([line hasPrefix:@" "])
				{
					line = [line substringFromIndex:1];
				}
			}
			
			[self _processLine:line withIndex:lineIndex allowAutoDetection:YES];
			
			if (willCloseTag)
			{
				// end of paragraph
				[self _popTag];
			}
		}
	}];
	
	// pop all remaining open tags
	while ([_tagStack count])
	{
		[self _popTag];
	}
	
	if (_delegateFlags.supportsEndDocument)
	{
		[_delegate parserDidEndDocument:self];
	}
	
	return YES;
}

#pragma mark - Properties

- (void)setDelegate:(id<DTMarkdownParserDelegate>)delegate
{
	_delegate = delegate;
	
	_delegateFlags.supportsStartDocument = ([_delegate respondsToSelector:@selector(parserDidStartDocument:)]);
	_delegateFlags.supportsEndDocument = ([_delegate respondsToSelector:@selector(parserDidEndDocument:)]);
	_delegateFlags.supportsFoundCharacters = ([_delegate respondsToSelector:@selector(parser:foundCharacters:)]);
	_delegateFlags.supportsStartTag = ([_delegate respondsToSelector:@selector(parser:didStartElement:attributes:)]);
	_delegateFlags.supportsEndTag = ([_delegate respondsToSelector:@selector(parser:didEndElement:)]);
}

@end
