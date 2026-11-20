use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP qw(encode_json decode_json);

my $root = tempdir(CLEANUP => 1);
make_path("$root/bin", "$root/tools");
for my $script (qw(build_container deploy_container)) {
    copy("$FindBin::Bin/../bin/$script", "$root/bin/$script") or die $!;
}

# Record argv without ever invoking Docker, Google Cloud, or a real registry.
my $fake_tool = <<'PERL';
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Basename qw(basename);
my $tool = basename($0);
open my $log, '>>', $ENV{MOCK_LOG} or die $!;
print {$log} encode_json([$tool, @ARGV]), "\n";
close $log;
if (($ENV{MOCK_FAIL} // '') eq "$tool:$ARGV[0]") {
    print STDERR "Simulated $tool failure\n";
    exit 7;
}
if ($tool eq 'gcloud' && join(' ', @ARGV[0..3]) eq 'artifacts docker images describe') {
    print(($ENV{MOCK_BAD_DIGEST} ? 'not-a-digest' : 'sha256:' . ('a' x 64)), "\n");
}
if ($tool eq 'gcloud' && join(' ', @ARGV[0..2]) eq 'run services describe') {
    print "https://api-proxy.example.run.app\n";
}
PERL
for my $tool (qw(gcloud docker)) {
    open my $fh, '>', "$root/tools/$tool" or die $!;
    print {$fh} $fake_tool;
    close $fh;
    chmod 0755, "$root/tools/$tool" or die $!;
}

my $digest = 'sha256:' . ('a' x 64);
my $image_path = 'europe-west1-docker.pkg.dev/test-project/containers/api-proxy';
my $image_ref = "$image_path\@$digest";

sub read_file {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<', $path or die $!;
    local $/;
    return <$fh>;
}

sub run_script {
    my ($script, $overrides, $image_file) = @_;
    local %ENV = (
        PATH => "$root/tools:$ENV{PATH}",
        PROJECT_ID => 'test-project',
        TAG => 'test-commit',
        MOCK_LOG => "$root/commands.jsonl",
        GITHUB_OUTPUT => "$root/output.txt",
        %{$overrides || {}},
    );
    unlink "$root/commands.jsonl", "$root/output.txt", "$root/image_ref.txt", "$root/service_url.txt";
    if (defined $image_file) {
        open my $fh, '>', "$root/image_ref.txt" or die $!;
        print {$fh} "$image_file\n";
        close $fh;
    }
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, 'bash', "$root/bin/$script");
    my $stdout = do { local $/; <$out> // '' };
    my $stderr = do { local $/; <$err> // '' };
    waitpid($pid, 0);
    my $exit = $? >> 8;
    my @commands = map { decode_json($_) } grep { length } split /\n/, read_file("$root/commands.jsonl");
    return ($exit, \@commands, $stdout . $stderr);
}

subtest 'build publishes an amd64 image and outputs only its digest to Actions' => sub {
    my ($exit, $commands) = run_script('build_container');
    is($exit, 0, 'Build succeeds');
    my ($build) = grep { $_->[0] eq 'docker' && $_->[1] eq 'build' } @$commands;
    ok($build, 'Docker build was invoked');
    like(join(' ', @$build), qr/--platform linux\/amd64/, 'Cloud Run architecture is explicit');
    like(join(' ', @$build), qr/--tag \Q$image_path\E:test-commit/, 'Build is tagged with the commit');
    ok((grep { $_->[0] eq 'docker' && $_->[1] eq 'push' } @$commands), 'Image is pushed');
    is(read_file("$root/image_ref.txt"), "$image_ref\n", 'Local output pins the registry digest');
    is(read_file("$root/output.txt"), "digest=$digest\n", 'Only digest crosses the workflow boundary');
};

subtest 'registry and digest failures stop the build' => sub {
    my ($exit, $commands) = run_script('build_container', { MOCK_FAIL => 'gcloud:artifacts' });
    is($exit, 7, 'Registry permission failure propagates');
    ok(!(grep { $_->[0] eq 'docker' && $_->[1] eq 'push' } @$commands), 'Nothing is pushed after preflight fails');
    ($exit) = run_script('build_container', { MOCK_BAD_DIGEST => 1 });
    isnt($exit, 0, 'Invalid registry digest is rejected');
    ok(!-e "$root/image_ref.txt", 'No invalid image reference is saved');
};

subtest 'deploy binds a secret reference and a dedicated runtime identity' => sub {
    my ($exit, $commands, $output) = run_script('deploy_container', {
        IMAGE_REF => $image_ref,
        GOOGLE_MAPS_API_KEY => 'key-payload-must-never-be-forwarded',
    });
    is($exit, 0, 'Deploy succeeds');
    my ($deploy) = grep { $_->[0] eq 'gcloud' && $_->[1] eq 'run' && $_->[2] eq 'deploy' } @$commands;
    my $args = join ' ', @$deploy;
    like($args, qr/--image \Q$image_ref\E/, 'Deploy uses an immutable image');
    like($args, qr/--project test-project --region europe-west1/, 'Project and region are explicit');
    like($args, qr/--service-account api-proxy-run\@test-project\.iam\.gserviceaccount\.com/, 'Dedicated runtime account is selected');
    like($args, qr/--update-secrets GOOGLE_MAPS_API_KEY=google-maps-api-key:1/, 'API key comes from a pinned Secret Manager version');
    like($args, qr/--concurrency 2/, 'Request concurrency matches default workers');
    like($args, qr/--allow-unauthenticated/, 'Public proxy can be invoked');
    unlike(encode_json($commands) . $output, qr/key-payload-must-never-be-forwarded/, 'Raw API key never enters argv or output');
    is(read_file("$root/service_url.txt"), "https://api-proxy.example.run.app\n", 'Service URL is saved');
};

subtest 'local image file and deployment overrides are supported' => sub {
    my ($exit, $commands) = run_script('deploy_container', {
        ALLOW_UNAUTH => 'false', WORKERS => 4,
        RUNTIME_SERVICE_ACCOUNT => 'custom@test-project.iam.gserviceaccount.com',
        GOOGLE_MAPS_API_KEY_SECRET => 'custom-maps-key',
        GOOGLE_MAPS_API_KEY_SECRET_VERSION => '7',
    }, $image_ref);
    is($exit, 0, 'Deploy reads the local image reference');
    my ($deploy) = grep { $_->[1] eq 'run' && $_->[2] eq 'deploy' } @$commands;
    my $args = join ' ', @$deploy;
    like($args, qr/--no-allow-unauthenticated/, 'Private access can be selected');
    like($args, qr/--concurrency 4/, 'Concurrency follows worker override');
    like($args, qr/GOOGLE_MAPS_API_KEY=custom-maps-key:7/, 'Secret metadata can be overridden');
    like($args, qr/--service-account custom\@test-project/, 'Runtime identity can be overridden');
};

subtest 'unsafe or incomplete deploy inputs fail before cloud access' => sub {
    for my $overrides (
        {},
        { IMAGE_REF => "$image_path:latest" },
        { IMAGE_REF => "other.registry/app\@$digest" },
        { IMAGE_REF => $image_ref, GOOGLE_MAPS_API_KEY_SECRET_VERSION => 'latest' },
        { IMAGE_REF => $image_ref, WORKERS => '0' },
        { IMAGE_REF => $image_ref, ALLOW_UNAUTH => 'maybe' },
        { IMAGE_REF => $image_ref, PROJECT_ID => '' },
    ) {
        my ($exit, $commands) = run_script('deploy_container', $overrides);
        isnt($exit, 0, 'Invalid input is rejected');
        is(scalar @$commands, 0, 'No cloud command runs for invalid input');
    }
};

subtest 'failed deploy does not report a successful URL' => sub {
    my ($exit, $commands) = run_script('deploy_container', {
        IMAGE_REF => $image_ref, MOCK_FAIL => 'gcloud:run',
    });
    is($exit, 7, 'Deploy failure propagates');
    is(scalar @$commands, 1, 'Service is not described after a failed deploy');
    ok(!-e "$root/service_url.txt", 'No service URL is saved');
};

done_testing;
