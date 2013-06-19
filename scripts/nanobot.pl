use warnings;
use strict;
use Sys::Hostname;
use File::stat;
use Encode qw/encode/;
use POSIX qw/strftime/;
use Cwd;
use Data::Dumper;
use Text::ParseWords;
use List::MoreUtils qw(uniq);

my $home = $ENV{NANOBOT_HOME} // "$ENV{HOME}/nanobot";

sub get_user_timezone {
	my ($nick) = @_;
	eval {
		use Net::LDAP;
		my $ldap = Net::LDAP->new("ldapi:///");
		$ldap->bind;
		my $res = $ldap->search(
				base => "ou=people,dc=cluenet,dc=org",
				scope => "one",
				filter => "(|(uid=$nick)(clueIrcNick=$nick))",
				attrs => ["timezone"],
				timelimit => 7);
		my @res = map {$_->get_value("timezone")} $res->entries;
		shift @res;
	};
}

my %emails = ();
my $emails_time = 0;
my $email_db = "$home/emails.txt";

sub sjoin {
	my @args = grep {defined} @_;
	if (@args) {
		my $last = pop(@args);
		@args ? join(" and ", join(", ", @args), $last) : $last;
	} else {
		"";
	}
}

## Convert a nickname to lowercase
# IRC treats [\] and {|} as equal
sub lc_irc {
	my $foo = shift;
	$foo =~ tr/\[\\\]/{|}/;
	return lc $foo;
}

sub roll {
	my ($quantity, $max) = @_;
	$max //= 6;

	my (@numbers, $total);
	if ($quantity == 0) {
		@numbers = ($total = 42);
	}
	for (1..$quantity) {
		my $x = sprintf("%d", rand($max-1)+1);
		push @numbers, $x;
		$total += $x;
	}
	return join(", ", @numbers).", for a total of $total";
}

## Store a memo to be sent later
sub memo_store {
	my ($server, $from, $from_host, $to, $text, $channel, $recvtime) = @_;
	$to = lc_irc $to; $to =~ s!/!!g;

	load_emails();

	my $do_mail = 0;
	my $do_store = 1;
	my $mail_to;

	my $to_orig = $to;
	my @fwdpath = ();

	while (1) {
		push @fwdpath, $to;
		my $next = $emails{$to};
		if (defined $next) {
			print "forwarding $to => '$next'";
			if ($next =~ /^:noirc$/) {
				$do_store = 0;
				$do_mail = 0;
				last;
			}
			elsif ($next =~ /^(.+):noirc$/) {
				#rint "using mail '$1' as final (no store)";
				$do_store = 0;
				$do_mail = 1; $mail_to = $1;
				last;
			}
			elsif ($next =~ /\@/) {
				#rint "using mail '$next' as final";
				$do_mail = 1; $mail_to = $next;
				last;
			}
			else {
				$next = lc_irc $next;
				if (grep {$_ eq $next} @fwdpath) {
					print "ignoring '$next' as next (loop ".join("!", @fwdpath).")";
					$to = $to_orig;
					last;
				} else {
					#rint "using nick '$next' as next";
					$to = $next;
				}
			}
		} else {
			#rint "no forward for '$to'";
			last;
		}
	}

	print "Accepted memo (".
		($do_mail ? "mail=<$mail_to>" : "mail=no").
		" store=".($do_store ? "yes" : "no").
		" path=".join("!", @fwdpath).")";

=old code
	if (defined $emails{$to}) {
		$mail_to = $emails{$to};
		$do_mail = 1;
		if ($mail_to =~ /^(.*):nosave$/) {
			$mail_to = $1;
			$do_store = 0;
		}
	}
=cut

	if ($do_store) {
		open my $fh, ">>", "$home/memos/$to.db"
			or warn;
		print $fh join("\t", $recvtime, $channel, $from, $text);
		print $fh "\n";
		close $fh;
	}

	if ($do_mail) {
		#my $nanobot_from = "$from\@nanobot.nathan7.eu";
		my $nanobot_from = "nanobot+$from\@panther.nathan7.eu";
		open my $s, "|-", ("/usr/sbin/sendmail",
					"-f", $nanobot_from,
					"-i",
					"--", $mail_to);

		my $hop = shift @fwdpath;
		while (scalar @fwdpath) {
			print $s qq{X-Forwarded: from "$hop" to "$fwdpath[0]"\n};
			$hop = shift @fwdpath;
		}

		# add a Received header
		my $date = eval {no locale;
				strftime "%a, %d %b %Y %H:%M:%S %z", localtime $recvtime};
		print $s
			qq[Received: from "$from" ($from_host)\n].
			qq[\tby "$server->{nick}" ($server->{username}\@$server->{tag})\n].
			qq[\tfor "$to_orig" via IRC (channel $channel);\n].
			qq[\t$date\n];

		print $s qq[X-Nanobot-Sender: $from!$from_host\n];
		print $s qq[X-Nanobot-Channel: $channel\n]
			if defined $channel;
		print $s qq[X-Nanobot-Recipient: $to\n];

		# use sender's email address as From header
		if (exists $emails{lc_irc $from}) {
			my $mail_from = $emails{lc_irc $from};
			$mail_from =~ s/:[a-z]+$//;
			print $s qq[Reply-To: $mail_from\n];
		}
		print $s qq[From: $from on ClueNet <$nanobot_from>\n];
		print $s qq[To: "$to_orig" <$mail_to>\n];
		print $s qq[Subject: Memo from $from\n];
		print $s qq[Content-Type: text/plain; charset=utf-8\n];

		# end header
		print $s qq[\n];

		# body
		print $s
			qq[$text\n].
			qq[\n].
			qq[--\040\n].
			qq[$from on $channel, via nanobot\n];

		close $s;
	}

	return $do_store + $do_mail;
}

## Check if $nick has any memos
sub memo_check {
	my ($nick) = @_;
	$nick = lc_irc $nick; $nick =~ s!/!!g;
	my $file = "$home/memos/$nick.db";
	return (-s $file);
}

## Read all memos to $nick
sub memo_read {
	my ($nick) = @_;

	$nick = lc_irc $nick; $nick =~ s!/!!g;
	my $dbfile = "$home/memos/$nick.db";

	my @memos = ();
	return () if !(-s $dbfile);

	open my $fh, "<", $dbfile;
	while (my $line = <$fh>) {
		chomp $line;
		my ($time, $channel, $sender, $text) = split "\t", $line, 4;
		if ($channel eq "*") {
			$channel = undef;
		}
		push @memos, {
			timestamp => $time,
			sender => $sender,
			where => $channel,
			text => $text,
		};
	}
	close $fh;
	return @memos;
}

## Move all memos to $nick to archive
sub memo_archive {
	my ($nick) = @_;

	$nick = lc_irc $nick; $nick =~ s!/!!g;
	my $dbfile = "$home/memos/$nick.db";

	open my $fh, "<", $dbfile;
	open my $archivefh, ">>", "$home/memos/sent/$nick.db";

	while (my $line = <$fh>) {
		print $archivefh $line;
	}

	close $fh;
	close $archivefh;
	unlink $dbfile;
}

sub memo_give {
	my ($server, $nick, $target) = @_;
	return if !memo_check($nick);

	my $c = 0;
	for my $memo (memo_read($nick)) {
		my $age = time - $memo->{timestamp};
		if ($age < 10) {
			$server->command("action $target beeps") if !$c++;
			next;
		}

		my $sender = $memo->{sender};
		# $sender .= "/".$memo->{where} if defined $memo->{where};
		my $text = $memo->{text};

		my $day = 86400;
		my $fmt = do {
			# *memodate*
			if ($age < $day/2)	{'%H:%M'}
			elsif ($age < $day*3)	{'%a, %H:%M'}
			elsif ($age < $day*5)	{'%b %-d, %H:%M'}
			elsif ($age < $day*60)	{'%b %-d'}
			else			{'%Y %b %-d'}
		};
		my $time = strftime($fmt, gmtime($memo->{timestamp}));
		$server->command("msg $target $nick: ($time) <$sender> $text");
	}
	memo_archive($nick);
}

sub mtime($) {
	my $stat = stat(shift);
	return defined $stat? $stat->mtime : 0;
}

sub _load_keyvalue {
	my ($db, $hash) = @_;
	open my $s, "<", $db;
	while (my $line = <$s>) {
		chomp $line; next if $line =~ /^#/;
		my @line = split " ", $line, 2;
		my $nick = lc_irc $line[0];
		$hash->{$nick} = $line[1];
	}
	close $s;
}

sub _save_keyvalue {
	my ($db, $hash) = @_;
	open my $s, ">", $db;
	for my $nick (sort keys %$hash) {
		printf $s "%s %s\n", $nick, $hash->{$nick};
	}
	close $s;
}

sub load_emails {
	my $dbtime = mtime $email_db;
	return unless ($dbtime > $emails_time);
	$emails_time = $dbtime;
	%emails = ();
	_load_keyvalue($email_db, \%emails);
}

sub save_emails {
	_save_keyvalue($email_db, \%emails);
}

sub d { Irssi::print($_[0]); }

sub shell_esc {
	my $str = shift;
	$str =~ s/'/'\\''/g;
	return "'$str'";
}

my %powerup;

sub pubmsg {
	my ($server, $msg, $nick, $addr, $target) = @_;

	my $my_nick = $server->{nick};
	
	my $ischannel = $server->ischannel($target);

	# send memos
	if ($my_nick and $nick !~ /^_?nanobot/) {
		memo_give($server, $nick, $target);
	}

	if ($ischannel && $msg =~ /^
			((↑|\^|up)\s*){2}
			((↓|v|down)\s*){2}
			((⇆|←\s*→|↔|<\s*>|left\s*right)\s*){2}
			b\s*a(\s*start)?
		/ix) {
		my $_nick = lc_irc($nick);
		if (exists $powerup{$_nick} && time - $powerup{$_nick} < 600) {
			return;
		}
		$powerup{$_nick} = time;
		$server->command("^msg ChanServ voice $target $nick");
		$server->command("^notice $nick POWERUP UNLOCKED: SIGN OF L33TNESS");
		Irssi::timeout_add_once(1000*60, sub {
			my $data = shift;
			my ($server, $target, $nick) = @$data;
			$server->command("^msg ChanServ devoice $target $nick");
			$server->command("^notice $nick POWERUP EXPIRED");
		}, [$server, $target, $nick]);
		return;
	}

	# compat:
	my $srcNick = $nick;
	my $srcAddress = $addr;

	my ($cmd, $cmd_directed, @args);

	if ($msg =~ /^\Q$my_nick\E[:,] (.*)$/) {
		$cmd = $1; $cmd_directed = 1;
	} elsif ($msg =~ /^,(.*)$/) {
		$cmd = $1; $cmd_directed = 0;
	} else {
		return;
	}

	my $replyto = $server->ischannel($target) ? $target : $nick;

	$cmd =~ s/\s+$//g;

	$ENV{REMOTE_USER} = $nick;
	$ENV{REMOTE_HOST} = $addr;
	$ENV{QUERY_TARGET} = $target;
	$ENV{QUERY_STRING} = $cmd;

	if ($cmd eq 'help') {
		$server->command("^notice $nick $_") for (
			"--- nanomemo service ---",
			"\002,memo\002 <nick> <message>  Send a memo",
			"\002,setmail\002 <email>        Forward memos (see \037,help setmail\037)",
			"--- other nanobot commands --",
			"\002,d\002 [posix_tz] [format]  Display current Gregorian date",
			"\002,ddate\002 [format]         Display current Discordian date",
			"\002,dns\002 <host|ipaddr>      DNS resolution (IPv4)",
			"\002,dns6\002 <host|ipaddr>     DNS resolution (IPv6)",
			"\002,gcalc\002 <expression>     Google Calculator",
			"\002,id\002 <user|uid>          Look up a Cluenet account",
			"\002,passwd\002 <user|uid>      Look up a passwd entry",
			"\002,roll\002 <XdY>             Roll dice",
			"--- end ---",
		);
	}
	elsif ($cmd =~ /^id\s+(\S+)$/) {
		$server->command("exec - -msg $target /home/nanobot/bin/nb.id $1");
	}
	elsif ($cmd =~ /^passwd\s+(\S+)$/) {
		$server->command("exec - -msg $target /home/nanobot/bin/nb.getpwent $1");
	}
	elsif ($cmd =~ /^points\s+(.+)$/) {
		my $args = join(" ", map {shell_esc($_)} split(/\s+/, $1));
		$server->command("exec - -msg $target ~/bin/nb.points $args");
	}
	elsif ($cmd =~ /^dns([46]?) (.+)$/) {
		my $v = ($1 or "4");
		$server->command("exec - -msg $target ~/bin/nb.dns ".shell_esc($nick).' '.shell_esc($2).' '.$v);
	}
	elsif($cmd=~/^ping (.*)$/){
		$server->command("exec - -msg $target /home/nathan/bin/ircping ".shell_esc($1));
	}
	elsif ($cmd =~ /^gcalc (the answer to life, the universe and everything)$/) {
		$server->command("msg $target $nick: $1 = 41.99999999999999...");
	}
	elsif($cmd=~/^gcalc 2\s*\+\s*2\s*$/){
		$server->command("/msg $target $nick: 2 + 2 = 5 (for sufficiently large values of 2)");
	}
	elsif($cmd=~/^gcalc (?:1 )?nathans? in (?:eur|euros|usd|dollars|us dollars)/i){
		$server->command("/msg $target $nick: Priceless.");
	}
	elsif($cmd=~/^gcalc (?:[0-9]* )?(whore|prostitute|blowjob)s? in (?:eur|euros|usd|dollars|us dollars)/i){
		$server->command("/msg $target $nick: Pricing information currently not available.");
	}
	elsif($cmd=~/^gcalc (a |1 )?cookies? in (?:eur|euros|usd|dollars|us dollars)/i){
		my $title = ($nick =~ /^(joannac|lamia|crazytales)/i)? "ma'am" : "sir";

		$server->command("/msg $target $nick: For you $title? Free.");
		$server->command("/action $target gives $nick a cookie");
		$server->command("/msg $target $nick: Your order has been delivered. Have a clueful day!");
	}
	elsif($cmd=~/^gcalc (.*)$/){
		$server->command("exec - -msg $target /home/nanobot/bin/nb.gcalc ".shell_esc($1));
	}
#	elsif($cmd=~/^gdef(?:ine)? (.*)$/){
#		$server->command("exec - -msg $target /home/nathan/bin/ircgdefine ".shell_esc($nick).' '.shell_esc($1));
#	}

#	elsif ($cmd =~ /^roll [Rr]ick$/) {
#		Irssi::timeout_add_once(1000*15, sub {
#			$server->command("nick $my_nick");
#		}, "");
#		$server->command("nick NGGYU");
#	}
	elsif ($cmd =~ /^roll (\d{1,2})(?:d(\d{1,6}))?$/) {
		my $r = roll($1, $2);
		$server->command("msg $target $nick got $r");
	}
	elsif ($cmd eq "roll") {
		$server->command("^notice $nick $_") for (
			"Usage: \002roll X\002 or \002roll XdY\002, where X is count and Y is max"
		);
	}
	elsif ($cmd =~ /^4lw ([0-9.]+)/) {
		$server->command("exec - -msg $target /home/nathan/bin/irc4lw ".shell_esc($nick).' '.shell_esc($1));
	}
	elsif ($cmd =~ /^dd(?:\s+(\S+))?$/) {
		my (@exec, $exec);
		my $nick = lc ($1 // $nick);

		my $TZ = get_user_timezone($nick);

		if (!defined $TZ) {
			$server->command("msg $target I don't know ${nick}'s timezone.");
			return;
		}
		
		unshift @exec, ("env", "TZ=$TZ", "date");

		push @exec, "+%a, %d %b %Y %H:%M:%S %z ($TZ)";

		$exec = join(" ", map {s/[\$\`\"\\]/\\$&/g; qq/"$_"/} @exec);
		$server->command("exec - -msg $target $exec");
	}
	elsif ($cmd =~ /^d(?:ate)?(\s+.+)?$/) {
		my (@format, @wantdate, @exec, $exec);
		my $TZ = "UTC";

		my $args = $1 // "";
		for (shellwords($args)) {
			if (/^([+-])(\d{1,2})$/) {
				# +N and -N hour offsets
				$TZ = "UTC$1$2";
				$TZ =~ y/+-/-+/;
			} elsif (/^([+-])(\d{2}):?(\d{2})$/) {
				# +NNNN and -NNNN offsets
				$TZ = "UTC$1$2:$3";
				$TZ =~ y/+-/-+/;
			} elsif (/^:?[\w-]+\/[\w-]+$/) {
				# Location/City timezone specifiers
				$TZ = $_;
			} elsif (/^[A-Z]{3,4}$/) {
				# TLA timezone specifiers
				$TZ = uc $_;
			} elsif (/^(@\d+)$/) {
				push @wantdate, $_;
			} elsif (/^@(.+)$/) {
				# @blah human-readable times
				@wantdate = ($1);
			} elsif (/%/) {
				push @format, $_;
			} else {
				push @wantdate, $_;
			}
		}

		unshift @exec, ("env", "TZ=$TZ", "date");
		if (scalar @format) {
			push @exec, '+'.join(" ", @format);
		} else {
			push @exec, '+%a, %d %b %Y %H:%M:%S %z (%Z)';
		}
		if (scalar @wantdate) {
			push @exec, "-d", join(" ", @wantdate);
		}

		$exec = join(" ", map {s/[\$\`\"\\]/\\$&/g; qq/"$_"/} @exec);
		#$server->command("msg $target $exec");
		$server->command("exec - -msg $target $exec");
	}

	elsif ($cmd =~ /^ddate(?:\s+(.+))?$/) {
		my ($format, @exec, $exec);
		@exec = ("ddate");
		if (defined $1) {
			push @exec, "+$1";
		}
		$exec = join " ", map {s/[\$\`\"\\]/\\$&/g; qq/"$_"/} @exec;
		$server->command("exec - -msg $target $exec");
	}

	elsif (@args = $cmd =~ /^sshfp ([A-Za-z0-9-:.]+?)(?: (\d+))?$/) {
		my ($host, $port) = @args;
		my $exec = "~/bin/nb.keyscan '$host' '$port'";
		$server->command("exec - -msg $target $exec");
	}

	elsif (@args = $cmd =~ /^memo( send)?\s+((?:[^\s]+(?:,\s*|\s*,\s+))*[^\s]+)\s+(.+)$/) {
		my ($foo, $rcpts, $memo) = @args;
		my $time = time;
		my (@success, @fail, @rcpts, @msg);
		@rcpts = grep {length} split(/\s*,\s*/, $rcpts);
		if (@rcpts > 5) {
			push @msg, "Lick my battery.";
		} else {
			for my $rcpt (uniq @rcpts) {
				if (memo_store($server, $nick, $addr, $rcpt, $memo, $target, $time)) {
					push @success, $rcpt;
				} else {
					push @fail, $rcpt;
				}
			}

			my $success = sjoin(@success);
			my $fail = sjoin(@fail);

			if (@success and @fail) {
				push @msg, "Memo sent to $success (failed: $fail)";
			} elsif (@success) {
				if (defined $foo and $foo =~ /send/) {
					push @msg, "Do I look like MemoServ to you? Fine, memo served.";
				} else {
					push @msg, "Memo to $success sent.";
				}
			} elsif (@fail) {
				push @msg, "Failed to send memo to $fail.";
			} else {
				push @msg, "wat";
			}
		}
		$server->command("msg $target $nick: $_") for @msg;
	}

	elsif ($cmd =~ /^setmail$/) {
		load_emails;
		my $addr = $emails{lc_irc $nick};

		my $msg;
		if (defined $addr) {
			if ($addr =~ /^:noirc$/) {
				$msg = "I discard all memos you receive.";
			} elsif ($addr !~ /\@/) {
				$msg = "I forward all your memos to user \002$addr\002";
			} elsif ($addr =~ /(.+):noirc$/) {
				$msg = "I forward all your memos to \002$1\002";
			} else {
				$msg = "I send a copy of your memos to \002$addr\002";
			}
		} else {
			$msg = "No email address on record; you will be notified about memos on IRC.";
		}
		$server->command("^notice $nick $msg");
	}

	elsif ($cmd =~ /^setmail help$/ or $cmd =~ /^help setmail$/) {
		$server->command("^notice $nick $_") for (
			"--- nanomemos: forwarding ---",
			"\002,setmail \037email\037\002        Forward your memos to email",
			"\002,setmail \037email\037:noirc\002  ...but don't notify on IRC",
			"\002,setmail \037nickname\037\002     Forward to another user",
			"\002,setmail none\002         Disable forwarding",
			"--- end ---",
		);
	}

	elsif ($cmd =~ /^setmail (.*)$/) {
		my $addr = $1;
		my $k = lc_irc $nick;
		load_emails;
		if ($addr =~ /^(\*|-|none|)$/) {
			if (defined $emails{$k}) {
				delete $emails{$k};
				$server->command("^notice $nick Email unset.");
				save_emails;
			}
		}
		else {
			$emails{$k} = $addr;
			$server->command("^notice $nick Email set to $addr");
			save_emails;
		}
	}

	elsif ($cmd =~ /^magic load email database$/) {
		load_emails;
		$server->command(sprintf("^notice %s %s entries (mtime %d)", $nick, scalar keys %emails, $emails_time));
	}

	elsif ($cmd =~ /^uptime$/) {
		$server->command("^msg $replyto ".hostname.": ".`uptime`);
	}

	elsif ($cmd =~ /^xyzzy$/) {
		$server->command("^msg $replyto Nothing happens.");
	}

	delete $ENV{REMOTE_USER};
	delete $ENV{REMOTE_HOST};
	delete $ENV{QUERY_TARGET};
	delete $ENV{QUERY_STRING};
}
sub privmsg{
	my ($server,$msg,$nick,$srcAddress)=@_;
#	$server->command("/msg #nanobot ".$server->{tag}." <$nick!$srcAddress> $msg");
}
sub invite{
	my ($server,$channel,$nick,$srcAddress)=@_;
	$server->channels_join($channel, 1);
	$server->command("action ".$channel." moos contentedly at ".$nick);
}
sub jchan{
	my ($channel)=@_;
	my $server=$channel->{server};
	$server->command("/msg #nanobot ".$server->{"tag"}." +".$channel->{"name"});
	chan($channel);
}
sub pchan{
	my ($channel)=@_;
	my $server=$channel->{server};
	$server->command("/msg #nanobot ".$server->{"tag"}." -".$channel->{"name"});
	chan($channel);
}

sub on_action {
	my ($server, $msg, $nick, $addr, $target) = @_;

	if ($msg =~ /rolls (\d{1,2})(?:d(\d{1,6}))?$/) {
		my $r = roll($1, $2);
		$server->command("msg $target $nick got $r");
	}
	if ($server->{nick} eq 'nanobot' and $nick !~ /^_?nanobot/) {
		memo_give($server, $nick, $target);
	}
}
Irssi::signal_add "message irc action" => \&on_action;

sub chan{
	my ($channel)=@_;
	my $server=$channel->{"server"};
	if($channel->{"name"} eq '#nanobot'){
		$server->command("/join ".$channel->{"topic"}) if $server->{"nick"} eq 'nanobot';
		return;
	}
	if($server->{"nick"} eq 'nanobot'){
		$server->command("/topic #nanobot ".$server->get_channels());
	}
}
Irssi::signal_add_last('message invite','invite');
Irssi::signal_add_last('message public','pubmsg');
Irssi::signal_add_last('message private','privmsg');
Irssi::signal_add_last('channel joined','jchan');
Irssi::signal_add_first('channel destroyed','pchan');
#my $timer = Irssi::timeout_add(250,'pyrecv','');

load_emails();

foreach my $server (Irssi::servers) {
	$server->command("/msg #nanobot ".$server->{"tag"}." Ready.");
}
