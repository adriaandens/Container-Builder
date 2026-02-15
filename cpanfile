requires 'perl', '5.040';

requires 'Archive::Ar';
requires 'Archive::Tar';
requires 'IO::Uncompress::UnXz';
requires 'IO::Compress::Gzip';
requires 'IO::Uncompress::Gunzip';
requires 'Cwd';
requires 'DateTime';
requires 'File::Copy';
requires 'Crypt::Digest::SHA256';
requires 'LWP::Protocol::https';
requires 'LWP::Simple';
requires 'LWP::UserAgent';
requires 'DPKG::Packages::Parser';
requires 'JSON';

on test => sub {
	requires 'Test::More', '0.96';
	requires 'JSON';
};
