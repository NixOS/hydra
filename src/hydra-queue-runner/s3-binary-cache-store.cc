#include "s3-binary-cache-store.hh"

#include "nar-info.hh"

#include <aws/core/client/ClientConfiguration.h>
#include <aws/s3/S3Client.h>
#include <aws/s3/model/CreateBucketRequest.h>
#include <aws/s3/model/GetBucketLocationRequest.h>
#include <aws/s3/model/GetObjectRequest.h>
#include <aws/s3/model/HeadObjectRequest.h>
#include <aws/s3/model/PutObjectRequest.h>

namespace nix {

struct S3Error : public Error
{
    Aws::S3::S3Errors err;
    S3Error(Aws::S3::S3Errors err, const FormatOrString & fs)
        : Error(fs), err(err) { };
};

/* Helper: given an Outcome<R, E>, return R in case of success, or
   throw an exception in case of an error. */
template<typename R, typename E>
R && checkAws(const FormatOrString & fs, Aws::Utils::Outcome<R, E> && outcome)
{
    if (!outcome.IsSuccess())
        throw S3Error(
            outcome.GetError().GetErrorType(),
            fs.s + ": " + outcome.GetError().GetMessage());
    return outcome.GetResultWithOwnership();
}

S3BinaryCacheStore::S3BinaryCacheStore(std::shared_ptr<Store> localStore,
    const Path & secretKeyFile, const Path & publicKeyFile,
    const std::string & bucketName)
    : BinaryCacheStore(localStore, secretKeyFile, publicKeyFile)
    , bucketName(bucketName)
    , config(makeConfig())
    , client(make_ref<Aws::S3::S3Client>(*config))
{
}

ref<Aws::Client::ClientConfiguration> S3BinaryCacheStore::makeConfig()
{
    auto res = make_ref<Aws::Client::ClientConfiguration>();
    res->region = Aws::Region::US_EAST_1;
    res->requestTimeoutMs = 600 * 1000;
    return res;
}

void S3BinaryCacheStore::init()
{
    /* Create the bucket if it doesn't already exists. */
    // FIXME: HeadBucket would be more appropriate, but doesn't return
    // an easily parsed 404 message.
    auto res = client->GetBucketLocation(
        Aws::S3::Model::GetBucketLocationRequest().WithBucket(bucketName));

    if (!res.IsSuccess()) {
        if (res.GetError().GetErrorType() != Aws::S3::S3Errors::NO_SUCH_BUCKET)
            throw Error(format("AWS error checking bucket ‘%s’: %s") % bucketName % res.GetError().GetMessage());

        checkAws(format("AWS error creating bucket ‘%s’") % bucketName,
            client->CreateBucket(
                Aws::S3::Model::CreateBucketRequest()
                .WithBucket(bucketName)
                .WithCreateBucketConfiguration(
                    Aws::S3::Model::CreateBucketConfiguration()
                    /* .WithLocationConstraint(
                       Aws::S3::Model::BucketLocationConstraint::US) */ )));
    }

    BinaryCacheStore::init();
}

const S3BinaryCacheStore::Stats & S3BinaryCacheStore::getS3Stats()
{
    return stats;
}

/* This is a specialisation of isValidPath() that optimistically
   fetches the .narinfo file, rather than first checking for its
   existence via a HEAD request. Since .narinfos are small, doing a
   GET is unlikely to be slower than HEAD. */
bool S3BinaryCacheStore::isValidPath(const Path & storePath)
{
    try {
        readNarInfo(storePath);
        return true;
    } catch (S3Error & e) {
        if (e.err == Aws::S3::S3Errors::NO_SUCH_KEY) return false;
        throw;
    }
}

bool S3BinaryCacheStore::fileExists(const std::string & path)
{
    stats.head++;

    auto res = client->HeadObject(
        Aws::S3::Model::HeadObjectRequest()
        .WithBucket(bucketName)
        .WithKey(path));

    if (!res.IsSuccess()) {
        auto & error = res.GetError();
        if (error.GetErrorType() == Aws::S3::S3Errors::UNKNOWN // FIXME
            && error.GetMessage().find("404") != std::string::npos)
            return false;
        throw Error(format("AWS error fetching ‘%s’: %s") % path % error.GetMessage());
    }

    return true;
}

void S3BinaryCacheStore::upsertFile(const std::string & path, const std::string & data)
{
    auto request =
        Aws::S3::Model::PutObjectRequest()
        .WithBucket(bucketName)
        .WithKey(path);

    auto stream = std::make_shared<std::stringstream>(data);

    request.SetBody(stream);

    stats.put++;
    stats.putBytes += data.size();

    auto now1 = std::chrono::steady_clock::now();

    auto result = checkAws(format("AWS error uploading ‘%s’") % path,
        client->PutObject(request));

    auto now2 = std::chrono::steady_clock::now();

    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();

    printMsg(lvlInfo, format("uploaded ‘s3://%1%/%2%’ (%3% bytes) in %4% ms")
        % bucketName % path % data.size() % duration);

    stats.putTimeMs += duration;
}

std::string S3BinaryCacheStore::getFile(const std::string & path)
{
    auto request =
        Aws::S3::Model::GetObjectRequest()
        .WithBucket(bucketName)
        .WithKey(path);

    request.SetResponseStreamFactory([&]() {
        return Aws::New<std::stringstream>("STRINGSTREAM");
    });

    stats.get++;

    auto now1 = std::chrono::steady_clock::now();

    auto result = checkAws(format("AWS error fetching ‘%s’") % path,
        client->GetObject(request));

    auto now2 = std::chrono::steady_clock::now();

    auto res = dynamic_cast<std::stringstream &>(result.GetBody()).str();

    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();

    printMsg(lvlTalkative, format("downloaded ‘s3://%1%/%2%’ (%3% bytes) in %4% ms")
        % bucketName % path % res.size() % duration);

    stats.getBytes += res.size();
    stats.getTimeMs += duration;

    return res;
}

}

