Добрый день! Перед Вами скрипт для резервного копирования датабаз PostgreSQL

Для корректного исполнения скрипта необходимо:

I. Настройки пользователя

1)Наличие (если нет, то создать) файл .pgpass в домашней директории пользователя, от имени которого будут выполняться копирования
Пример команды создания для пользователя postgres:

sudo -u postgres bash -c 'echo "localhost:5432:*:postgres:your_password" >> ~/.pgpass'

2)Установка корректных прав на .pgpass (если ещё не установлены):

sudo -u postgres chmod 600 ~/.pgpass


II. Настройки скрипта

1)Проверить валидность прав на диск под бэкапы и логи:

sudo chown postgres:postgres /backups
sudo chown postgres:postgres /var/log/backup.log #В задании не указано, существует ли уже файл. Будем считать, что он уже есть.

2)Сделать скрипт исполняемым (path_to_script замените на путь к скрипту):

sudo chmod +x path_to_script/pg_backup.sh
sudo chown postgres:postgres path_to_script/pg_backup.sh

III. Запуск скрипта

sudo -u postgres path_to_script/pg_backup.sh

Проверка логов в реальном времени
sudo tail -f /var/log/backup.log

1. Проверка создания бэкапа

sudo -u postgres ls -la /backups/

sudo -u postgres file /backups/backup_*.gz

2. Проверка содержимого архива
bash

sudo -u postgres tar -tzf /backups/backup_*.gz

sudo -u postgres du -h /backups/backup_*.gz







