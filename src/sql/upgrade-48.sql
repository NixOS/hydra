-- Add declarative fields to Projects
alter table Projects add column declfile text;
alter table Projects add column decltype text;
alter table Projects add column declvalue text;
