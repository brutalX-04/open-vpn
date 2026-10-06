from abc import ABC, abstractmethod


class Driver(ABC):
    @abstractmethod
    def create(self, *args, **kwargs): ...

    @abstractmethod
    def delete(self, *args, **kwargs): ...

    @abstractmethod
    def renew(self, *args, **kwargs): ...

    @abstractmethod
    def disconnect(self, *args, **kwargs): ...

    @abstractmethod
    def count_online(self): ...
