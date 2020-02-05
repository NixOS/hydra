-- will automatically add unique IDs to Jobsets.
ALTER TABLE Jobsets
  ADD COLUMN id SERIAL NOT NULL,
  ADD CONSTRAINT Jobsets_id_unique UNIQUE (id);
