use Test::Stream::Tester;
use strict;
use warnings;

use Test::Stream::Event::Skip;
use Test::Stream::DebugInfo;

my $skip = Test::Stream::Event::Skip->new(
    debug  => Test::Stream::DebugInfo->new(frame => [__PACKAGE__, __FILE__, __LINE__]),
    name   => 'skip me',
    reason => 'foo',
);

is($skip->name, 'skip me', "set name");
is($skip->reason, 'foo', "got skip reason");
ok(!$skip->pass, "no default for pass");
ok($skip->effective_pass, "TODO always effectively passes");

done_testing;
