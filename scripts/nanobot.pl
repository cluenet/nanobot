use warnings;
use strict;
use Sys::Hostname;
use File::stat;
use Encode qw/encode/;
use POSIX qw/strftime/;
use Cwd;
use Data::Dumper;
use Text::ParseWords;

my $home = $ENV{NANOBOT_HOME} // $ENV{HOME};

=changelog
Aug 07:	grawity
	Replace From/Sender with Reply-To
May 16: grawity
	Add timestamp to memo notices, remove channel name.
Mar 20: grawity
	Merge the access list with one in eval.pl
Oct 01: grawity
	,setmail accepts nicknames
Sep 29: grawity
	Added ,id and ,passwd
Sep 13: grawity
	Adjusted memomail to work better with Gmail message snippets
	Added ,help and ,help setmail
=cut

my %emails = ();
my $emails_time = 0;
my $email_db = "$home/emails.txt";

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
	my ($server, $from, $from_host, $to, $text, $channel) = @_;
	$to = lc_irc $to; $to =~ s!/!!g;
	my $recvtime = time;

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
		open my $s, "|-", ("/usr/sbin/sendmail", "-i", "--", $mail_to);

		my $hop = shift @fwdpath;
		while (scalar @fwdpath) {
			print $s qq{X-Forwarded: from "$hop" to "$fwdpath[0]"\n};
			$hop = shift @fwdpath;
		}

		# add a Received header
		my $date = eval {no locale; strftime "%a, %d %b %Y %H:%M:%S %z", localtime $recvtime};
		print $s
			qq[Received: from "$from" ($from_host)\n].
			qq[\tby "$server->{nick}" ($server->{username}\@$server->{tag})\n].
			qq[\tfor "$to_orig" via IRC (channel $channel); $date\n];

		print $s qq[X-Nanobot-Sender: $from!$from_host\n];
		#print $s qq[X-Nanobot-Channel: $channel\n]
		#	if defined $channel;
		print $s qq[X-Nanobot-Recipient: $to\n];

		# use sender's email address as From header
		if (exists $emails{lc_irc $from}) {
			my $mail_from = $emails{lc_irc $from};
			$mail_from =~ s/:[a-z]+$//;
			print $s qq[Reply-To: $mail_from\n];
		}
		print $s qq[From: "$from on ClueNet" <nanobot+$from>\n];
		print $s qq[To: "$to_orig" <$mail_to>\n];
		print $s qq[Subject: Memo from $from\n];

		print $s qq[\n];
		print $s qq[$text\n\n--\040\n$from on $channel, via nanobot\n];

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
	if (!memo_check($nick)) {return;}

	for my $memo (memo_read($nick)) {
		my $sender = $memo->{sender};
		# $sender .= "/".$memo->{where} if defined $memo->{where};
		my $text = $memo->{text};
		my $time = strftime('%b %d %H:%M', gmtime($memo->{timestamp}));
		$server->command("msg $target $nick: on $time <$sender> $text");
	}
	memo_archive($nick);
}

sub mtime($) {
	my $stat = stat(shift);
	return defined $stat? $stat->mtime : 0;
}

sub save_emails {
	open my $s, ">", $email_db;
	for my $nick (keys %emails) {
		printf $s "%s %s\n", $nick, $emails{$nick};
	}
	close $s;
}

sub load_emails {
	my $dbtime = mtime $email_db;
	return unless ($dbtime > $emails_time);

	%emails = ();
	$emails_time = $dbtime;
	open my $s, "<", $email_db;
	while (my $line = <$s>) {
		chomp $line; next if $line =~ /^#/;

		my @line = split " ", $line, 2;
		my $nick = lc_irc $line[0];
		$emails{$nick} = $line[1];
	}
	close $s;
}

sub d { Irssi::print($_[0]); }

sub shell_esc {
	my $str = shift;
	$str =~ s/'/'\\''/g;
	return "'$str'";
}

sub pubmsg {
	my ($server, $msg, $nick, $addr, $target) = @_;

	my $my_nick = $server->{nick};

	# send memos
	if ($my_nick and $nick !~ /^_?nanobot/) {
		memo_give($server, $nick, $target);
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
			"--- other nanobot commands --",
			"\002,d\002 [posix_tz] [format]  Display current Gregorian date",
			"\002,ddate\002 [format]         Display current Discordian date",
			"\002,dns\002 <host|ipaddr>      DNS resolution",
			"\002,dns6\002 <host|ipaddr>     DNS resolution (IPv6)",
			"\002,gcalc\002 <expression>     Google Calculator",
			"\002,id\002 <user|uid>          Look up an account",
			"\002,passwd\002 <user|uid>      Look up a passwd entry",
			"\002,setmail\002                Forward memos (see \037,help setmail\037)",
			"--- end ---",
		);
	}
	elsif ($cmd =~ /^id ([0-9a-z-_]+)$/) {
		$server->command("exec - -msg $target /home/nanobot/bin/nb.id $1");
	}
	elsif ($cmd =~ /^passwd ([0-9a-z-_]+)$/) {
		$server->command("exec - -msg $target /home/nanobot/bin/nb.getpwent $1");
	}
	elsif($cmd=~/^dns([46]?) (.+)$/){
		my $v = ($1 or "4");
		$server->command("exec - -msg $target /home/nathan/bin/ircdns ".shell_esc($srcNick).' '.shell_esc($2).' '.$v);
	}
	elsif($cmd=~/^ping (.*)$/){
		$server->command("exec - -msg $target /home/nathan/bin/ircping ".shell_esc($1));
	}
	elsif ($cmd =~ /^gcalc (the answer to life, the universe and everything)$/) {
		$server->command("msg $target $srcNick: $1 = 41.99999999999999...");
	}
	elsif($cmd=~/^gcalc 2\s*\+\s*2\s*$/){
		$server->command("/msg $target $srcNick: 2 + 2 = 5 (for sufficiently large values of 2)");
	}
	elsif($cmd=~/^gcalc (?:1 )?nathans? in (?:eur|euros|usd|dollars|us dollars)/i){
		$server->command("/msg $target $srcNick: Priceless.");
	}
	elsif($cmd=~/^gcalc (?:[0-9]* )?(whore|prostitute|blowjob)s? in (?:eur|euros|usd|dollars|us dollars)/i){
		$server->command("/msg $target $srcNick: Pricing information currently not available.");
	}
	elsif($cmd=~/^gcalc (a |1 )?cookies? in (?:eur|euros|usd|dollars|us dollars)/i){
		my $title = ($srcNick =~ /^(joannac|lamia|crazytales)/i)? "ma'am" : "sir";

		$server->command("/msg $target $srcNick: For you $title? Free.");
		$server->command("/action $target gives $srcNick a cookie");
		$server->command("/msg $target $srcNick: Your order has been delivered. Have a clueful day!");
	}
	elsif($cmd=~/^gcalc (.*)$/){
		$server->command("exec - -msg $target /home/nanobot/bin/nb.gcalc ".shell_esc($1));
	}
#	elsif($cmd=~/^gdef(?:ine)? (.*)$/){
#		$server->command("exec - -msg $target /home/nathan/bin/ircgdefine ".shell_esc($srcNick).' '.shell_esc($1));
#	}

	elsif ($cmd =~ /^roll (\d{1,2})(?:d(\d{1,6}))?$/) {
		my $r = roll($1, $2);
		$server->command("msg $target $srcNick got $r");
	}
	elsif ($cmd eq "roll") {
		$server->command("^notice $srcNick $_") for (
			"Usage: roll XdY, where X is count and Y is max"
		);
	}
	elsif ($cmd =~ /^4lw ([0-9.]+)/) {
		$server->command("exec - -msg $target /home/nathan/bin/irc4lw ".shell_esc($srcNick).' '.shell_esc($1));
	}
	elsif ($cmd =~ /^d(?:ate)?( .+)?$/) {
		my (@format, @wantdate, @exec, $exec);
		my $TZ = "UTC";

		my $args = $1 // "";
		for (shellwords($args)) {
			if (/^([+-])(\d{1,2})$/) {
				# +N and -N hour offsets
				$TZ = "GMT$1$2";
				$TZ =~ y/+-/-+/;
			} elsif (/^[\w-]+\/[\w-]+$/) {
				# Location/City timezone specifiers
				$TZ = $_;
			} elsif (/^[A-Z]{3,4}$/) {
				# TLA timezone specifiers
				$TZ = uc $_;
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

	elsif ($cmd =~ /^ddate(?: (.+))?$/) {
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

	elsif (@args = $cmd =~ /^memo (.+?) (.+)$/) {
		my ($rcpt, $memo) = @args;
		my $stored = memo_store($server, $nick, $addr, $rcpt, $memo, $target);

		my $verb = $stored ? "sent" : "discarded";
		$server->command("msg $target $nick: Memo to $rcpt $verb.");
	}

	elsif ($cmd =~ /^setmail$/) {
		load_emails;
		my $addr = $emails{lc_irc $srcNick};

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
		$server->command("^notice $srcNick $msg");
	}

	elsif ($cmd =~ /^setmail help$/ or $cmd =~ /^help setmail$/) {
		$server->command("^notice $srcNick $_") for (
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
		my $k = lc_irc $srcNick;
		load_emails;
		if ($addr =~ /^(\*|-|none|)$/) {
			if (defined $emails{$k}) {
				delete $emails{$k};
				$server->command("^notice $srcNick Email unset.");
				save_emails;
			}
		}
		else {
			$emails{$k} = $addr;
			$server->command("^notice $srcNick Email set to $addr");
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
	my ($server,$msg,$srcNick,$srcAddress)=@_;
#	$server->command("/msg #nanobot ".$server->{tag}." <$srcNick!$srcAddress> $msg");
}
sub invite{
	my ($server,$channel,$srcNick,$srcAddress)=@_;
	$server->channels_join($channel, 1);
	$server->command("action ".$channel." moos contentedly at ".$srcNick);
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
