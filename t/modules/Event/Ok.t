use strict;
use warnings;

use Test::Stream::Tester;
use Test::Stream::State;
use Test::Stream::DebugInfo;
use Test::Stream::Event::Ok;
use Test::Stream::Event::Diag;

use Test::Stream::Context qw/context/;

my $dbg;
sub tests {
    my ($name, $code) = @_;

    # Make sure there is a fresh debug object for each group
    $dbg = Test::Stream::DebugInfo->new(
        frame => ['main_foo', 'foo.t', 42, 'main_foo::flubnarb'],
    );

    my $ok = eval { $code->(); 1 };
    my $err = $@;
    my $ctx = context();
    $ctx->ok($ok, $name, [$err]);
    $ctx->release;
}

tests Passing => sub {
    my $ok = Test::Stream::Event::Ok->new(
        debug => $dbg,
        pass  => 1,
        name  => 'the_test',
    );
    ok(!$ok->causes_fail, "Passing 'OK' event does not cause failure");
    is($ok->pass, 1, "got pass");
    is($ok->name, 'the_test', "got name");
    is($ok->effective_pass, 1, "effective pass");
    is($ok->diag, undef, "no diag");

    my $state = Test::Stream::State->new;
    $ok->update_state($state);
    is($state->count, 1, "Added to the count");
    is($state->is_passing, 1, "still passing");
};

tests Failing => sub {
    local $ENV{HARNESS_ACTIVE} = 1;
    local $ENV{HARNESS_IS_VERBOSE} = 1;
    my $ok = Test::Stream::Event::Ok->new(
        debug => $dbg,
        pass  => 0,
        name  => 'the_test',
    );
    ok($ok->causes_fail, "A failing test causes failures");
    is($ok->pass, 0, "got pass");
    is($ok->name, 'the_test', "got name");
    is($ok->effective_pass, 0, "effective pass");

    is(
        $ok->default_diag,
        "Failed test 'the_test'\nat foo.t line 42.",
        "default diag"
    );

    my $state = Test::Stream::State->new;
    $ok->update_state($state);
    is($state->count, 1, "Added to the count");
    is($state->failed, 1, "Added to failed count");
    is($state->is_passing, 0, "not passing");
};

tests fail_with_diag => sub {
    local $ENV{HARNESS_ACTIVE} = 1;
    local $ENV{HARNESS_IS_VERBOSE} = 1;
    my $ok = Test::Stream::Event::Ok->new(
        debug => $dbg,
        pass  => 0,
        name  => 'the_test',
        diag  => ['xxx'],
    );
    is($ok->pass, 0, "got pass");
    is($ok->name, 'the_test', "got name");
    is($ok->effective_pass, 0, "effective pass");

    is_deeply(
        $ok->diag,
        [ "xxx" ],
        "Got diag"
    );

    my $state = Test::Stream::State->new;
    $ok->update_state($state);
    is($state->count, 1, "Added to the count");
    is($state->failed, 1, "Added to failed count");
    is($state->is_passing, 0, "not passing");
};

tests "Failing TODO" => sub {
    local $ENV{HARNESS_ACTIVE} = 1;
    local $ENV{HARNESS_IS_VERBOSE} = 1;
    my $ok = Test::Stream::Event::Ok->new(
        debug => $dbg,
        pass  => 0,
        name  => 'the_test',
        todo  => 'A Todo',
    );
    is($ok->pass, 0, "got pass");
    is($ok->name, 'the_test', "got name");
    is($ok->effective_pass, 1, "effective pass is true from todo");

    $ok->set_diag([ $ok->default_diag ]);
    is_deeply(
        $ok->diag,
        [ "Failed (TODO) test 'the_test'\nat foo.t line 42." ],
        "Got diag"
    );

    my $state = Test::Stream::State->new;
    $ok->update_state($state);
    is($state->count, 1, "Added to the count");
    is($state->failed, 0, "failed count unchanged");
    is($state->is_passing, 1, "still passing");

    $ok = Test::Sync::Event::Ok->new(
        debug => $dbg,
        pass  => 0,
        name  => 'the_test2',
        todo  => '',
    );
    ok($ok->effective_pass, "empty string todo is still a todo");
};

tests init => sub {
    like(
        exception { Test::Stream::Event::Ok->new() },
        qr/No debug info provided!/,
        "Need to provide debug info"
    );

    like(
        exception { Test::Stream::Event::Ok->new(debug => $dbg, pass => 1, name => "foo#foo") },
        qr/'foo#foo' is not a valid name, names must not contain '#' or newlines/,
        "Some characters do not belong in a name"
    );

    like(
        exception { Test::Stream::Event::Ok->new(debug => $dbg, pass => 1, name => "foo\nfoo") },
        qr/'foo\nfoo' is not a valid name, names must not contain '#' or newlines/,
        "Some characters do not belong in a name"
    );

    my $ok = Test::Stream::Event::Ok->new(
        debug => $dbg,
        pass  => 1,
    );
    is($ok->effective_pass, 1, "set effective pass");

    $ok = Test::Stream::Event::Ok->new(
        debug => $dbg,
        pass  => 1,
        name => 'foo#foo',
        allow_bad_name => 1,
    );
    ok($ok, "allowed the bad name");
};

tests default_diag => sub {
    my $ok = Test::Stream::Event::Ok->new(debug => $dbg, pass => 1);
    is_deeply([$ok->default_diag], [], "no diag for a pass");

    $ok = Test::Stream::Event::Ok->new(debug => $dbg, pass => 0);
    like($ok->default_diag, qr/Failed test at foo\.t line 42/, "got diag w/o name");

    $ok = Test::Stream::Event::Ok->new(debug => $dbg, pass => 0, name => 'foo');
    like($ok->default_diag, qr/Failed test 'foo'\nat foo\.t line 42/, "got diag w/name");
};

done_testing;
