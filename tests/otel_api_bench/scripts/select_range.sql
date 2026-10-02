\set start random(1, 99001)
SELECT v FROM ft WHERE id >= :start AND id < :start + 1000;
