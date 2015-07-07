#pragma once

#include <pqxx/pqxx>

#include "util.hh"


struct Connection : pqxx::connection
{
    Connection() : pqxx::connection(getFlags()) { };

    std::string getFlags()
    {
        using namespace nix;
        auto s = getEnv("HYDRA_DBI", "dbi:Pg:dbname=hydra;");
        std::string prefix = "dbi:Pg:";
        if (std::string(s, 0, prefix.size()) != prefix)
            throw Error("$HYDRA_DBI does not denote a PostgreSQL database");
        return concatStringsSep(" ", tokenizeString<Strings>(string(s, prefix.size()), ";"));
    }
};


struct receiver : public pqxx::notification_receiver
{
    bool status = false;
    receiver(pqxx::connection_base & c, const std::string & channel)
        : pqxx::notification_receiver(c, channel) { }
    void operator() (const std::string & payload, int pid) override
    {
        status = true;
    };
    bool get() {
        bool b = status;
        status = false;
        return b;
    }
};
