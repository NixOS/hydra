create table StarredJobs (
    userName      text not null,
    project       text not null,
    jobset        text not null,
    job           text not null,
    primary key   (userName, project, jobset, job),
    foreign key   (userName) references Users(userName) on update cascade on delete cascade,
    foreign key   (project) references Projects(name) on update cascade on delete cascade,
    foreign key   (project, jobset) references Jobsets(project, name) on update cascade on delete cascade,
    foreign key   (project, jobset, job) references Jobs(project, jobset, name) on update cascade on delete cascade
);
