alter table Builds add column notificationPendingSince integer;

create index IndexBuildsOnNotificationPendingSince on Builds(notificationPendingSince) where notificationPendingSince is not null;
