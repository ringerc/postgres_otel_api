\set id random(1, 100000)
UPDATE ft SET v = v WHERE id = :id;
