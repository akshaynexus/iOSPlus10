/* The rows of the XNUtils screen: switches, actions, status line, the report's sections (tap a line to open it). */
#import "vc.h"
#ifdef XT_IOS26
#import "bench.h"
#endif

static NSString *const kActions[] = { @"Clear Metal strikes", @"Restart UI (backboardd)", @"Copy report", @"Share report", @"Restart", @"Reboot to bootloader", @"Shut down" };

static UIColor *
state_color(NSString *s)
{
	if ([s isEqualToString:@"on"]) return UIColor.systemGreenColor;
	if ([s isEqualToString:@"off"]) return UIColor.systemRedColor;
	if ([s isEqualToString:@"part"]) return UIColor.systemOrangeColor;
	if ([s isEqualToString:@"info"]) return UIColor.systemBlueColor;
	return UIColor.systemGrayColor;
}

@implementation ViewController (List)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
	return 3 + (NSInteger)self.sections.count;              /* switches, actions, status line, then the report */
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
#ifdef XT_IOS26
	if (section == 0) return 4;
#else
	if (section == 0) return 3;
#endif
	if (section == 1) return NUM_ACTIONS;
	if (section == 2) return 1;
	XTSection *s = self.sections[(NSUInteger)section - 3];
	return [self.open containsObject:s.title] ? 1 + (NSInteger)s.rows.count : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
	return section == 0 ? @"Switches" : section == 1 ? @"Actions" : section == 2 ? @"Report: tap a line to open it" : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
	return section == 0 ? @"Both apply to processes that start later. Restart UI applies them to backboardd and SpringBoard." : nil;
}

- (UITableViewCell *)labelCell:(UITableView *)tv {
	UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"row"];

	if (c == nil) {
		c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
		c.textLabel.numberOfLines = 0;
		c.detailTextLabel.numberOfLines = 0;
	}
	c.accessoryView = nil;
	c.accessoryType = UITableViewCellAccessoryNone;
	c.textLabel.textColor = UIColor.labelColor;
	c.textLabel.font = [UIFont systemFontOfSize:15];
	c.detailTextLabel.text = nil;
	c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	c.detailTextLabel.font = [UIFont systemFontOfSize:12];
	c.selectionStyle = UITableViewCellSelectionStyleDefault;
	return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	if (ip.section == 0 && ip.row == 1) {
		return self.metalCell;
	}
	UITableViewCell *c = [self labelCell:tv];

	if (ip.section == 0) {
		c.selectionStyle = UITableViewCellSelectionStyleNone;
#ifdef XT_IOS26
		if (ip.row == 3) {
			c.selectionStyle = UITableViewCellSelectionStyleDefault;
			c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			c.textLabel.text = @"Metal options and bench";
			c.detailTextLabel.text = @"Stack, Turnip mode, live glass; the same scene on each, two runs side by side.";
			return c;
		}
#endif
		if (ip.row == 0) {
			c.textLabel.text = @"Metal";
			c.detailTextLabel.text = @"Auto: the gate tests at the next boot. All: every process but backboardd and mediaserverd. Probes: test tools only. Off: no device.";
		} else {
			c.textLabel.text = @"GL for backboardd";
			c.detailTextLabel.text = @"Off: CoreAnimation's software renderer after Restart UI.";
			c.accessoryView = self.gl;
		}
		return c;
	}
	if (ip.section == 1) {
		c.textLabel.text = kActions[ip.row];
		c.textLabel.textColor = ip.row >= 4 ? UIColor.systemRedColor : UIColor.systemBlueColor;
		return c;
	}
	if (ip.section == 2) {
		c.textLabel.text = self.note;
		c.textLabel.font = [UIFont systemFontOfSize:12];
		c.textLabel.textColor = UIColor.secondaryLabelColor;
		c.selectionStyle = UITableViewCellSelectionStyleNone;
		return c;
	}
	XTSection *s = self.sections[(NSUInteger)ip.section - 3];

	if (ip.row == 0) {
		NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:@"● " attributes:@{ NSForegroundColorAttributeName : state_color(s.state) }];

		[t appendAttributedString:[[NSAttributedString alloc] initWithString:s.title attributes:@{ NSFontAttributeName : [UIFont boldSystemFontOfSize:16], NSForegroundColorAttributeName : UIColor.labelColor }]];
		c.textLabel.attributedText = t;
		c.detailTextLabel.text = s.reason.length ? [NSString stringWithFormat:@"%@: %@", s.state, s.reason] : s.state;
		c.accessoryType = UITableViewCellAccessoryNone;
		return c;
	}
	XTRow *row = s.rows[(NSUInteger)ip.row - 1];

	c.selectionStyle = UITableViewCellSelectionStyleNone;
	c.textLabel.text = row.key;
	c.textLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
	c.detailTextLabel.text = row.age >= 5 ? [NSString stringWithFormat:@"%@ (%ld s ago)", row.value, (long)row.age] : row.value;
	if ([row.value isEqualToString:@"not available"]) {
		c.detailTextLabel.textColor = UIColor.tertiaryLabelColor;
	}
	return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:NO];
#ifdef XT_IOS26
	if (ip.section == 0 && ip.row == 3) {
		UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:[[XTBenchController alloc] initWithStyle:UITableViewStyleInsetGrouped]];

		[self presentViewController:n animated:YES completion:nil];
		return;
	}
#endif
	if (ip.section == 1) {
		[self action:ip.row];
	} else if (ip.section >= 3 && ip.row == 0) {
		NSString *title = self.sections[(NSUInteger)ip.section - 3].title;

		if ([self.open containsObject:title]) {
			[self.open removeObject:title];
		} else {
			[self.open addObject:title];
		}
		[tv reloadData];
	}
}

@end
