#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 55;
use File::Temp qw(tempdir);

use lib qw(/opt/rt3/local/lib /opt/rt3/lib);
require RT::Test; import RT::Test;
require "t/rtir-test.pl";

{
    $RT::Handle->InsertSchema(undef, '/opt/rt3/local/etc/FM');
    $RT::Handle->InsertACL(undef, '/opt/rt3/local/etc/FM');

    $RT::Handle = new RT::Handle;
    $RT::Handle->dbh( undef );
    RT->ConnectToDatabase;

    local @INC = ('/opt/rt3/local/etc', '/opt/rt3/etc', @INC);
    RT->Config->LoadConfig(File => "IR/RTIR_Config.pm");
    $RT::Handle->InsertData('IR/initialdata');

    $RT::Handle = new RT::Handle;
    $RT::Handle->dbh( undef );
    RT->ConnectToDatabase;
}

RT::Test->set_mail_catcher;

RT->Config->Set( 'GnuPG',
                 Enable => 1,
                 OutgoingMessagesFormat => 'RFC' );

RT->Config->Set( GnuPGOptions =>
    homedir => scalar tempdir( CLEANUP => 0 ),
    passphrase => 'rt-test',
    'no-permission-warning' => undef,
);
diag "GnuPG --homedir ". RT->Config->Get('GnuPGOptions')->{'homedir'};

RT->Config->Set( 'MailPlugins' => 'Auth::MailFrom', 'Auth::GnuPG' );

my $queue = RT::Test->load_or_create_queue(
    Name              => 'Incident Reports',
    CorrespondAddress => 'rt-recipient@example.com',
    CommentAddress    => 'rt-recipient@example.com',
);
ok $queue && $queue->id, 'loaded or created queue';

my ($baseurl, $agent) = RT::Test->started_ok;
rtir_user();
$agent->login( rtir_test_user => 'rtir_test_pass' );


RT::Test->set_rights(
    Principal => 'Everyone',
    Right => ['CreateTicket', 'ShowTicket', 'SeeQueue', 'ReplyToTicket', 'ModifyTicket'],
);

{
    RT::Test->import_gnupg_key('rt-recipient@example.com');
    RT::Test->trust_gnupg_key('rt-recipient@example.com');
    my %res = RT::Crypt::GnuPG::GetKeysInfo('rt-recipient@example.com');
    is $res{'info'}[0]{'TrustTerse'}, 'ultimate', 'ultimately trusted key';
}

diag "check that things don't work if there is no key";
{
    unlink "t/mailbox";

    ok $agent->goto_create_ticket( $queue ), "UI -> create ticket";
    $agent->form_number(3);
    $agent->tick( Encrypt => 1 );
    $agent->field( Requestors => 'rt-test@example.com' );
    $agent->field( Content => 'Some content' );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/There is no key suitable for encryption/i,
        'problems with keys'
    );

    my $form = $agent->form_number(3);
    ok !$form->find_input( 'UseKey-rt-test@example.com' ), 'no key selector';

    my @mail = RT::Test->fetch_caught_mails;
    ok !@mail, 'there are no outgoing emails';
}

diag "import first key of rt-test\@example.com";
my $fpr1 = '';
{
    RT::Test->import_gnupg_key('rt-test@example.com', 'public');
    my %res = RT::Crypt::GnuPG::GetKeysInfo('rt-test@example.com');
    is $res{'info'}[0]{'TrustLevel'}, 0, 'is not trusted key';
    $fpr1 = $res{'info'}[0]{'Fingerprint'};
}

diag "check that things still doesn't work if key is not trusted";
{
    unlink "t/mailbox";

    ok $agent->goto_create_ticket( $queue ), "UI -> create ticket";
    $agent->form_number(3);
    $agent->tick( Encrypt => 1 );
    $agent->field( Requestors => 'rt-test@example.com' );
    $agent->field( Content => 'Some content' );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/There is one suitable key, but trust level is not set/i,
        'problems with keys'
    );

    my $form = $agent->form_number(3);
    ok my $input = $form->find_input( 'UseKey-rt-test@example.com' ), 'found key selector';
    is scalar $input->possible_values, 1, 'one option';

    $agent->select( 'UseKey-rt-test@example.com' => $fpr1 );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/Selected key either is not trusted/i,
        'problems with keys'
    );

    my @mail = RT::Test->fetch_caught_mails;
    ok !@mail, 'there are no outgoing emails';
}

diag "import a second key of rt-test\@example.com";
my $fpr2 = '';
{
    RT::Test->import_gnupg_key('rt-test@example.com.2', 'public');
    my %res = RT::Crypt::GnuPG::GetKeysInfo('rt-test@example.com');
    is $res{'info'}[1]{'TrustLevel'}, 0, 'is not trusted key';
    $fpr2 = $res{'info'}[2]{'Fingerprint'};
}

diag "check that things still doesn't work if two keys are not trusted";
{
    unlink "t/mailbox";

    ok $agent->goto_create_ticket( $queue ), "UI -> create ticket";
    $agent->form_number(3);
    $agent->tick( Encrypt => 1 );
    $agent->field( Requestors => 'rt-test@example.com' );
    $agent->field( Content => 'Some content' );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/There are several keys suitable for encryption/i,
        'problems with keys'
    );

    my $form = $agent->form_number(3);
    ok my $input = $form->find_input( 'UseKey-rt-test@example.com' ), 'found key selector';
    is scalar $input->possible_values, 2, 'two options';

    $agent->select( 'UseKey-rt-test@example.com' => $fpr1 );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/Selected key either is not trusted/i,
        'problems with keys'
    );

    my @mail = RT::Test->fetch_caught_mails;
    ok !@mail, 'there are no outgoing emails';
}

{
    RT::Test->lsign_gnupg_key( $fpr1 );
    my %res = RT::Crypt::GnuPG::GetKeysInfo('rt-test@example.com');
    ok $res{'info'}[0]{'TrustLevel'} > 0, 'trusted key';
    is $res{'info'}[1]{'TrustLevel'}, 0, 'is not trusted key';
}

diag "check that we see key selector even if only one key is trusted but there are more keys";
{
    unlink "t/mailbox";

    ok $agent->goto_create_ticket( $queue ), "UI -> create ticket";
    $agent->form_number(3);
    $agent->tick( Encrypt => 1 );
    $agent->field( Requestors => 'rt-test@example.com' );
    $agent->field( Content => 'Some content' );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/There are several keys suitable for encryption/i,
        'problems with keys'
    );

    my $form = $agent->form_number(3);
    ok my $input = $form->find_input( 'UseKey-rt-test@example.com' ), 'found key selector';
    is scalar $input->possible_values, 2, 'two options';

    my @mail = RT::Test->fetch_caught_mails;
    ok !@mail, 'there are no outgoing emails';
}

diag "check that key selector works and we can select trusted key";
{
    unlink "t/mailbox";

    ok $agent->goto_create_ticket( $queue ), "UI -> create ticket";
    $agent->form_number(3);
    $agent->tick( Encrypt => 1 );
    $agent->field( Requestors => 'rt-test@example.com' );
    $agent->field( Content => 'Some content' );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/There are several keys suitable for encryption/i,
        'problems with keys'
    );

    my $form = $agent->form_number(3);
    ok my $input = $form->find_input( 'UseKey-rt-test@example.com' ), 'found key selector';
    is scalar $input->possible_values, 2, 'two options';

    $agent->select( 'UseKey-rt-test@example.com' => $fpr1 );
    $agent->click('Create');
    $agent->content_like( qr/Ticket \d+ created in queue/i, 'ticket created' );

    my @mail = RT::Test->fetch_caught_mails;
    ok @mail, 'there are some emails';
    check_text_emails( { Encrypt => 1 }, @mail );
}

diag "check encrypting of attachments";
{
    unlink "t/mailbox";

    ok $agent->goto_create_ticket( $queue ), "UI -> create ticket";
    $agent->form_number(3);
    $agent->tick( Encrypt => 1 );
    $agent->field( Requestors => 'rt-test@example.com' );
    $agent->field( Content => 'Some content' );
    $agent->field( Attachment => $0 );
    $agent->submit;
    $agent->content_like(
        qr/You are going to encrypt outgoing email messages/i,
        'problems with keys'
    );
    $agent->content_like(
        qr/There are several keys suitable for encryption/i,
        'problems with keys'
    );

    my $form = $agent->form_number(3);
    ok my $input = $form->find_input( 'UseKey-rt-test@example.com' ), 'found key selector';
    is scalar $input->possible_values, 2, 'two options';

    $agent->select( 'UseKey-rt-test@example.com' => $fpr1 );
    $agent->click('Create');
    $agent->content_like( qr/Ticket \d+ created in queue/i, 'ticket created' );

    my @mail = RT::Test->fetch_caught_mails;
    ok @mail, 'there are some emails';
    check_text_emails( { Encrypt => 1, Attachment => 1 }, @mail );
}

sub check_text_emails {
    my %args = %{ shift @_ };
    my @mail = @_;

    ok scalar @mail, "got some mail";
    for my $mail (@mail) {
        for my $type ('email', 'attachment') {
            next if $type eq 'attachment' && !$args{'Attachment'};

            my $content = $type eq 'email'
                        ? "Some content"
                        : "Attachment content";

            if ( $args{'Encrypt'} ) {
                unlike $mail, qr/$content/, "outgoing $type was encrypted";
            } else {
                like $mail, qr/$content/, "outgoing $type was not encrypted";
            } 

            next unless $type eq 'email';

            if ( $args{'Sign'} && $args{'Encrypt'} ) {
                like $mail, qr/BEGIN PGP MESSAGE/, 'outgoing email was signed';
            } elsif ( $args{'Sign'} ) {
                like $mail, qr/SIGNATURE/, 'outgoing email was signed';
            } else {
                unlike $mail, qr/SIGNATURE/, 'outgoing email was not signed';
            }
        }
    }
}


